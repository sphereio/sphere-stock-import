_ = require('underscore')._
Config = require '../config'
StockImport = require '../lib/stockimport'
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 10000

describe 'integration test', ->
  beforeEach (done) ->
    @stockimport = new StockImport Config
    @client = @stockimport.client

    console.info 'Deleting old inventory entires...'
    @client.inventoryEntries.perPage(0).fetch()
    .then (result) =>
      dels = _.map result.body.results, (e) =>
        @client.inventoryEntries.byId(e.id).delete(e.version)
      Q.all(dels)
      .then ->
        console.info "#{_.size dels} deleted."
        done()
    .fail (err) ->
      done err

  describe 'XML file', ->
    it 'Nothing to do', (done) ->
      @stockimport.run('<root></root>', 'XML')
      .then (result) ->
        expect(result).toBe 'Nothing to do.'
        done()
      .fail (err) ->
        done err

    it 'one new stock', (done) ->
      rawXml =
        '''
        <root>
          <row>
            <code>123</code>
            <quantity>2</quantity>
          </row>
        </root>
        '''
      @stockimport.run(rawXml, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 201
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '123'
        expect(stocks[0].quantityOnStock).toBe 2
        @stockimport.run(rawXml, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 304
        @client.inventoryEntries.fetch()
      .then (result) ->
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '123'
        expect(stocks[0].quantityOnStock).toBe 2
        done()
      .fail (err) ->
        done err

    it 'add more stock', (done) ->
      rawXml =
        '''
        <root>
          <row>
            <code>234</code>
            <quantity>7</quantity>
          </row>
        </root>
        '''
      rawXmlChanged = rawXml.replace('7', '19')
      @stockimport.run(rawXml, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 201
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '234'
        expect(stocks[0].quantityOnStock).toBe 7
        @stockimport.run(rawXmlChanged, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 200
        @client.inventoryEntries.fetch()
      .then (result) ->
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '234'
        expect(stocks[0].quantityOnStock).toBe 19
        done()
      .fail (err) ->
        done err

    it 'remove some stock', (done) ->
      rawXml =
        '''
        <root>
          <row>
            <code>1234567890</code>
            <quantity>77</quantity>
          </row>
        </root>
        '''
      rawXmlChanged = rawXml.replace('77', '-13')
      @stockimport.run(rawXml, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 201
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '1234567890'
        expect(stocks[0].quantityOnStock).toBe 77
        @stockimport.run(rawXmlChanged, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 200
        @client.inventoryEntries.fetch()
      .then (result) ->
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe '1234567890'
        expect(stocks[0].quantityOnStock).toBe -13
        done()
      .fail (err) ->
        done err

    it 'should create and update 2 stock entries when appointed quantity is given', (done) ->
      rawXml =
        '''
        <root>
          <row>
            <code>myEAN</code>
            <quantity>-1</quantity>
            <AppointedQuantity>10</AppointedQuantity>
            <CommittedDeliveryDate>1999-12-31T11:11:11.000Z</CommittedDeliveryDate>
          </row>
        </root>
        '''
      rawXmlChangedAppointedQuantity = rawXml.replace('10', '20')
      rawXmlChangedCommittedDeliveryDate = rawXml.replace('1999-12-31T11:11:11.000Z', '2000-01-01T12:12:12.000Z')

      @stockimport.run(rawXml, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 201
        expect(result[1].statusCode).toBe 201
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(stocks.length).toBe 2
        expect(stocks[0].sku).toBe 'myEAN'
        expect(stocks[0].quantityOnStock).toBe -1
        expect(stocks[0].supplyChannel).toBeUndefined()
        expect(stocks[1].sku).toBe 'myEAN'
        expect(stocks[1].quantityOnStock).toBe 10
        expect(stocks[1].supplyChannel).toBeDefined()
        expect(stocks[1].expectedDelivery).toBe '1999-12-31T11:11:11.000Z'
        @stockimport.run(rawXmlChangedAppointedQuantity, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 304
        expect(result[1].statusCode).toBe 200
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(stocks[0].sku).toBe 'myEAN'
        expect(stocks[0].quantityOnStock).toBe -1
        expect(stocks[0].supplyChannel).toBeUndefined()
        expect(stocks[1].sku).toBe 'myEAN'
        expect(stocks[1].quantityOnStock).toBe 20
        expect(stocks[1].supplyChannel).toBeDefined()
        expect(stocks[1].expectedDelivery).toBe '1999-12-31T11:11:11.000Z'
        @stockimport.run(rawXmlChangedCommittedDeliveryDate, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 304
        expect(result[1].statusCode).toBe 200
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(stocks[0].sku).toBe 'myEAN'
        expect(stocks[0].quantityOnStock).toBe -1
        expect(stocks[0].supplyChannel).toBeUndefined()
        expect(stocks[1].sku).toBe 'myEAN'
        expect(stocks[1].quantityOnStock).toBe 10
        expect(stocks[1].supplyChannel).toBeDefined()
        expect(stocks[1].expectedDelivery).toBe '2000-01-01T12:12:12.000Z'
        @stockimport.run(rawXmlChangedCommittedDeliveryDate, 'XML')
      .then (result) =>
        expect(result[0].statusCode).toBe 304
        expect(result[1].statusCode).toBe 304
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(stocks[0].sku).toBe 'myEAN'
        expect(stocks[0].quantityOnStock).toBe -1
        expect(stocks[0].supplyChannel).toBeUndefined()
        expect(stocks[1].sku).toBe 'myEAN'
        expect(stocks[1].quantityOnStock).toBe 10
        expect(stocks[1].supplyChannel).toBeDefined()
        expect(stocks[1].expectedDelivery).toBe '2000-01-01T12:12:12.000Z'
        done()
      .fail (err) ->
        done err

  describe 'CSV file', ->
    it 'CSV - one new stock', (done) ->
      raw =
        '''
        stock,quantity
        abcd,0
        '''
      @stockimport.run(raw, 'CSV')
      .then (result) =>
        expect(result[0].statusCode).toBe 201
        @client.inventoryEntries.fetch()
      .then (result) =>
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe 'abcd'
        expect(stocks[0].quantityOnStock).toBe 0
        @stockimport.run(raw, 'CSV')
      .then (result) =>
        expect(result[0].statusCode).toBe 304
        @client.inventoryEntries.fetch()
      .then (result) ->
        stocks = result.body.results
        expect(_.size stocks).toBe 1
        expect(stocks[0].sku).toBe 'abcd'
        expect(stocks[0].quantityOnStock).toBe 0
        done()
      .fail (err) ->
        done err
