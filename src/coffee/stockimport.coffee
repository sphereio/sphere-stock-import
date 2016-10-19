debug = require('debug')('sphere-stock-import')
_ = require 'underscore'
_.mixin require('underscore-mixins')
csv = require 'csv'
Promise = require 'bluebird'
{ElasticIo} = require 'sphere-node-utils'
{SphereClient, InventorySync} = require 'sphere-node-sdk'
package_json = require '../package.json'
xmlHelpers = require './xmlhelpers'

CHANNEL_KEY_FOR_XML_MAPPING = 'expectedStock'
CHANNEL_REF_NAME = 'supplyChannel'
CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']
LOG_PREFIX = "[SphereStockImport] "

HEADER_SKU = 'sku'
HEADER_QUANTITY = 'quantityOnStock'
HEADER_CUSTOM_TYPE = 'customType'
HEADER_CUSTOM_SEPERATOR = '.'
HEADER_CUSTOM_REGEX = new RegExp /^customField\./

class StockImport

  constructor: (@logger, options = {}) ->
    options = _.defaults options, {user_agent: 'sphere-stock-import'}
    @sync = new InventorySync
    @client = new SphereClient options
    @csvHeaders = options.csvHeaders
    @csvDelimiter = options.csvDelimiter
    @_resetSummary()

  _resetSummary: ->
    @_summary =
      emptySKU: 0
      created: 0
      updated: 0

  getMode: (fileName) ->
    switch
      when fileName.match /\.csv$/i then 'CSV'
      when fileName.match /\.xml$/i then 'XML'
      else throw new Error "Unsupported mode (file extension) for file #{fileName} (use csv or xml)"

  ###
  Elastic.io calls this for each csv row, so each inventory entry will be processed at a time
  ###
  elasticio: (msg, cfg, next, snapshot) ->
    debug 'Running elastic.io: %j', msg
    if _.size(msg.attachments) > 0
      for attachment of msg.attachments
        content = msg.attachments[attachment].content
        continue unless content
        encoded = new Buffer(content, 'base64').toString()
        mode = @getMode attachment
        @run encoded, mode, next
        .then (result) =>
          if result
            ElasticIo.returnSuccess result, next
          else
            @summaryReport()
            .then (message) ->
              ElasticIo.returnSuccess message, next
        .catch (err) ->
          ElasticIo.returnFailure err, next
        .done()

    else if _.size(msg.body) > 0
      _ensureChannel = =>
        if msg.body.CHANNEL_KEY?
          @client.channels.ensure(msg.body.CHANNEL_KEY, CHANNEL_ROLES)
          .then (result) ->
            debug 'Channel ensured, about to create or update: %j', result
            Promise.resolve(result.body.id)
        else
          Promise.resolve(msg.body.CHANNEL_ID)

      @client.inventoryEntries.where("sku=\"#{msg.body.SKU}\"").perPage(1).fetch()
      .then (results) =>
        debug 'Existing entries: %j', results
        existingEntries = results.body.results
        _ensureChannel()
        .then (channelId) =>
          stocksToProcess = [
            @_createInventoryEntry(msg.body.SKU, msg.body.QUANTITY, msg.body.EXPECTED_DELIVERY, channelId)
          ]
          @_createOrUpdate stocksToProcess, existingEntries
        .then (results) =>
          _.each results, (r) =>
            switch r.statusCode
              when 201 then @_summary.created++
              when 200 then @_summary.updated++
          @summaryReport()
        .then (message) ->
          ElasticIo.returnSuccess message, next
      .catch (err) ->
        debug 'Failed to process inventory: %j', err
        ElasticIo.returnFailure err, next
      .done()
    else
      ElasticIo.returnFailure "#{LOG_PREFIX}No data found in elastic.io msg.", next

  run: (fileContent, mode, next) ->
    @_resetSummary()
    if mode is 'XML'
      @performXML fileContent, next
    else if mode is 'CSV'
      @performCSV fileContent, next
    else
      Promise.reject "#{LOG_PREFIX}Unknown import mode '#{mode}'!"

  summaryReport: (filename) ->
    if @_summary.created is 0 and @_summary.updated is 0
      message = 'Summary: nothing to do, everything is fine'
    else
      message = "Summary: there were #{@_summary.created + @_summary.updated} imported stocks " +
        "(#{@_summary.created} were new and #{@_summary.updated} were updates)"

    if @_summary.emptySKU > 0
      message += "\nFound #{@_summary.emptySKU} empty SKUs from file input"
      message += " '#{filename}'" if filename

    message

  performXML: (fileContent, next) ->
    new Promise (resolve, reject) =>
      xmlHelpers.xmlTransform xmlHelpers.xmlFix(fileContent), (err, xml) =>
        if err?
          reject "#{LOG_PREFIX}Error on parsing XML: #{err}"
        else
          @client.channels.ensure(CHANNEL_KEY_FOR_XML_MAPPING, CHANNEL_ROLES)
          .then (result) =>
            stocks = @_mapStockFromXML xml.root, result.body.id
            @_perform stocks, next
          .then (result) -> resolve result
          .catch (err) -> reject err
          .done()

  performCSV: (fileContent, next) ->
    new Promise (resolve, reject) =>
      csv.parse fileContent, {delimiter: @csvDelimiter, trim: true}, (err, data) =>
        headers = data[0]
        @_getHeaderIndexes headers, @csvHeaders
        .then (mappedHeaderIndexes) =>
          stocks = @_mapStockFromCSV _.tail(data), mappedHeaderIndexes
          debug "Stock mapped from csv for headers #{mappedHeaderIndexes}: %j", stocks

          # TODO: ensure channel ??
          @_perform stocks, next
          .then (result) -> resolve result
        .catch (err) -> reject err
        .done()
      .on 'error', (error) ->
        reject "#{LOG_PREFIX}Problem in parsing CSV: #{error}"

  performStream: (chunk, cb) ->
    @_processBatches(chunk).then -> cb()

  _getHeaderIndexes: (headers, csvHeaders) ->
    Promise.all _.map csvHeaders.split(','), (h) =>
      cleanHeader = h.trim()
      mappedHeader = _.find headers, (header) -> header.toLowerCase() is cleanHeader.toLowerCase()
      if mappedHeader
        headerIndex = _.indexOf headers, mappedHeader
        debug "Found index #{headerIndex} for header #{cleanHeader}: %j", headers
        Promise.resolve(headerIndex)
      else
        Promise.reject "Can't find header '#{cleanHeader}' in '#{headers}'."

  _mapStockFromXML: (xmljs, channelId) ->
    stocks = []
    if xmljs.row?
      _.each xmljs.row, (row) =>
        sku = xmlHelpers.xmlVal row, 'code'
        stocks.push @_createInventoryEntry(sku, xmlHelpers.xmlVal(row, 'quantity'))
        appointedQuantity = xmlHelpers.xmlVal row, 'appointedquantity'
        if appointedQuantity?
          expectedDelivery = undefined
          committedDeliveryDate = xmlHelpers.xmlVal row, 'committeddeliverydate'
          if committedDeliveryDate
            try
              expectedDelivery = new Date(committedDeliveryDate).toISOString()
            catch error
              @logger.warn "Can't parse date '#{committedDeliveryDate}'. Creating entry without date..."
          d = @_createInventoryEntry(sku, appointedQuantity, expectedDelivery, channelId)
          stocks.push d
    stocks

  _mapStockFromCSV: (rows, mappedHeaderIndexes) ->
    # _.map rows, (row) =>
    #   sku = row[skuIndex].trim()
    #   quantity = row[quantityIndex]?.trim()
    #   @_createInventoryEntry sku, quantity
    _.map rows, (row) =>
      _data = {}
      _.each row, (cell, index) =>
        headerName = mappedHeaderIndexes[index]

        if HEADER_CUSTOM_REGEX.test headerName
          # check if custom type ID or key exists, else > error
          @_mapCustomField(_data, cell, headerName)
        else
          _data[headerName] = @_mapCellData(cell, headerName)
      _data

  _mapCellData: (data, headerName) ->
    data = data?.trim()

    switch on
      when HEADER_QUANTITY is headerName then parseInt(data, 10) or 0
      when HEADER_CUSTOM_TYPE is headerName then @_getCustomTypeDefinition(data)
      else data

  _mapCustomField: (data, cell, headerName) ->
    keyName = headerName.split(HEADER_CUSTOM_SEPERATOR)[1]

    if !isNaN(cell)
      cell = parseInt(cell, 10)

    if data.custom
      data.custom[keyName] = cell
    else
      # coffeelint: disable=coffeescript_error
      data.custom = {"#{keyName}": cell}
      # coffeelint: enable=coffeescript_error
  _getCustomTypeDefinition: _.memoize (customTypeKey) ->
    @__getCustomTypeDefinition customTypeKey

  # Should not be called directed.
  __getCustomTypeDefinition: (customTypeKey) ->
    @client.types.where("key = \"#{customTypeKey}\"").fetch()

  _createInventoryEntry: (sku, quantity, expectedDelivery, channelId) ->
    entry =
      sku: sku
      quantityOnStock: parseInt(quantity, 10) or 0 # avoid NaN
    entry.expectedDelivery = expectedDelivery if expectedDelivery?
    if channelId?
      entry[CHANNEL_REF_NAME] =
        typeId: 'channel'
        id: channelId
    entry

  _perform: (stocks, next) ->
    @logger.info "Stock entries to process: #{_.size(stocks)}"
    if _.isFunction next
      _.each stocks, (entry) ->
        msg =
          body:
            SKU: entry.sku
            QUANTITY: entry.quantityOnStock
        if entry.expectedDelivery?
          msg.body.EXPECTED_DELIVERY = entry.expectedDelivery
        if entry[CHANNEL_REF_NAME]?
          msg.body.CHANNEL_ID = entry[CHANNEL_REF_NAME].id
        ElasticIo.returnSuccess msg, next
      Promise.resolve "#{LOG_PREFIX}elastic.io messages sent."
    else
      @_processBatches(stocks)

  _processBatches: (stocks) ->
    batchedList = _.batchList(stocks, 30) # max parallel elem to process
    Promise.map batchedList, (stocksToProcess) =>
      debug 'Chunk: %j', stocksToProcess
      uniqueStocksToProcessBySku = @_uniqueStocksBySku(stocksToProcess)
      debug 'Chunk (unique stocks): %j', uniqueStocksToProcessBySku

      skus = _.map uniqueStocksToProcessBySku, (s) =>
        @_summary.emptySKU++ if _.isEmpty s.sku
        # TODO: query also for channel?
        "\"#{s.sku}\""
      predicate = "sku in (#{skus.join(', ')})"

      @client.inventoryEntries.all()
      .where(predicate)
      .fetch()
      .then (results) =>
        debug 'Fetched stocks: %j', results
        queriedEntries = results.body.results
        @_createOrUpdate stocksToProcess, queriedEntries
      .then (results) =>
        _.each results, (r) =>
          switch r.statusCode
            when 201 then @_summary.created++
            when 200 then @_summary.updated++
        Promise.resolve()
    , {concurrency: 1} # run 1 batch at a time

  _uniqueStocksBySku: (stocks) ->
    _.reduce stocks, (acc, stock) ->
      foundStock = _.find acc, (s) -> s.sku is stock.sku
      acc.push stock unless foundStock
      acc
    , []

  _match: (entry, existingEntries) ->
    _.find existingEntries, (existingEntry) ->
      if entry.sku is existingEntry.sku
        # check channel
        # - if they have the same channel, it's the same entry
        # - if they have different channels or one of them has no channel, it's not
        if _.has(entry, CHANNEL_REF_NAME) and _.has(existingEntry, CHANNEL_REF_NAME)
          entry[CHANNEL_REF_NAME].id is existingEntry[CHANNEL_REF_NAME].id
        else
          if _.has(entry, CHANNEL_REF_NAME) or _.has(existingEntry, CHANNEL_REF_NAME)
            false # one of them has a channel, the other not
          else
            true # no channel, but same sku
      else
        false

  _createOrUpdate: (inventoryEntries, existingEntries) ->
    debug 'Inventory entries: %j', {toProcess: inventoryEntries, existing: existingEntries}

    posts = _.map inventoryEntries, (entry) =>
      existingEntry = @_match(entry, existingEntries)
      if existingEntry?
        synced = @sync.buildActions(entry, existingEntry)
        if synced.shouldUpdate()
          @client.inventoryEntries.byId(synced.getUpdateId()).update(synced.getUpdatePayload())
        else
          Promise.resolve statusCode: 304
      else
        @client.inventoryEntries.create(entry)

    debug 'About to send %s requests', _.size(posts)
    Promise.all(posts)

module.exports = StockImport
