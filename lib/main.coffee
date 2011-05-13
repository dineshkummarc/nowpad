# Require
fs = require 'fs'
now = require 'now'
path = require 'path'
coffee = require 'coffee-script'
nowpadCommon = require(__dirname+'/public/common.coffee').nowpadCommon
nowpad = {}

# -------------------------------------
# Classes

class List
	# Storage
	items: {}
	length: 0

	# For each
	forEach: (callback) ->
		for item of @items
			callback(item)

	# Fetch an used id
	generateId: ->
		while true
			id = String Math.floor Math.random()*1000
			if typeof @items[id] is 'undefined'
				break
		return id
	
	# Add a new item to the list
	add: (id,item) ->
		@items[id] = item
		@length++
	
	# Get an item from the list
	get: (id) ->
		return @items[id]
	
	# Set an item from the list
	set: (id,item) ->
		if typeof @items[id] is 'undefined'
			throw new Error 'an item with the id of ['+id+'] does not exist'
		@items[id] = item
	
	# Remove an item from the list
	remove: (id) ->
		item = @get id
		delete @items[id]
		@length--
		return item
	
	# Destroy an item from the list
	destroy: (id) ->
		item = @get id
		@remove id
		item.destroy()

class Client
	# Required
	id: null
	info: {}

	# Optional
	documentIds: []

	# Constructor
	constructor: (id,info) ->
		@id = id
		@info = info
	
	# Destroy
	destroy: ->
		# Prepare
		clientId = @id

		# Clear Documents
		documentIds = @documentIds
		@documentIds = []

		# Destroy Documents
		for documentId in documentIds
			document = nowpad.documents.get(documentId)
			if document and typeof document.clientIds[clientId] is not 'undefined'
				delete document.clientIds[clientId]
				if document.clientIds.length is 0
					document.destroy()
	
		# Log
		console.log 'Destroyed Client', clientId

class Document
	# Required
	id: null

	# Optional
	value: ''
	state: false
	delay: 200
	states: []
	offset: 0
	locked: false
	clientIds: []

	# Constructor
	constructor: (id) ->
		@id = id

	# Lock
	lock: (clientId) ->
		success = false

		if !@locked
			@locked = clientId
			success = true
		
		return success
	
	# Unlock
	unlock: (clientId) ->
		success = false

		if @locked is clientId
			@locked = false
			success = true
		
		return success
	
	# Destroy
	destroy: ->
		# Prepare
		documentId = @id

		# Clear Clients
		clientIds = @clientIds
		@clientIds = []

		# Destroy Clients
		for clientId in clientIds
			client = nowpad.clients.get(clientId)
			if client and typeof document.documentIds[documentId] is not 'undefined'
				delete document.documentIds[documentId]
				if client.documentIds.length is 0
					client.destroy()
		
		# Log
		console.log 'Destroyed Document', documentId


# -------------------------------------
# Server

nowpad =
	# Server
	app: null
	everyone: null
	filePath: __dirname
	fileNames: [
		'public/diff_match_patch.js'
		'public/common.coffee'
		'public/client.coffee'
	]
	fileString: ''

	# Nowpad
	documents: new List(),
	clients: new List(), 
	
	# Events
	events:
		sync: []
		disconnected: []
	
	# Initialise
	init: ->
		nowpad.cacheClientScript()
	
	# Cache the client script
	cacheClientScript: ->
		nowpad.fileString = ''
		nowpad.fileNames.forEach (value) ->
			filePath = nowpad.filePath+'/'+value
			fs.readFile filePath, 'utf8', (err,data) ->
				throw err if err
				if path.extname(filePath) is '.coffee'
					nowpad.fileString += coffee.compile(data)
				else
					nowpad.fileString += data
	
	# Server the client script
	serveClientScript: (req,res) ->
		res.writeHead 200, 'content-type': 'text/javascript'
		res.write nowpad.fileString
		res.end()
	
	# Setup
	setup: (app) ->
		# Bind
		nowpad.app = app

		# Routes
		nowpad.app.get '/nowpad/nowpad.js', nowpad.serveClientScript
		
		# Now
		nowpad.nowInit()
	
	# Initialise Now.js
	nowInit: ->
		# Bind now to server
		everyone = now.initialize nowpad.app, {clientWrite: false}

		# A client has connected
		everyone.connected ->
			# Create the new client
			clientId = nowpad.clients.generateId()
			client = new Client(clientId)
			nowpad.clients.add(client)

			# Associate it with now
			@now.clientId = clientId

			# Log
			console.log 'New Client:', clientId

		# A client has disconnected
		everyone.disconnected ->
			# Fetch
			clientId = @now.clientId
			nowpad.clients.destroy @now.clientId

			# Log
			console.log 'Bye Client:', clientId
		
		# A client is shaking hands with the server
		everyone.now.handshake = (syncNotify,delayNotify,callback) ->
			# Check the user isn't evil
			if (typeof syncNotify isnt 'function') or (typeof delayNotify isnt 'function')
				console.log 'Evil client'
				return false
			
			# Apply the client-side functions used to notify the client to the now session
			@now.syncNotify = syncNotify
			@now.delayNotify = delayNotify

			# Trigger the callback
			if callback then callback()
		
		# Lock a document
		everyone.now.lockDocument = (documentId, callback) ->
			# Fetch Document
			document = nowpad.documents.get documentId
			unless document
				document = new Document(documentId)
				nowpad.documents.add(document)

			# Attempt document lock and send result back to client
			if callback then callback document.lock(@now.clientId)
		
		# Unlock
		everyone.now.unlockDocument = (documentId, callback) ->
			# Fetch Document
			document = nowpad.documents.get documentId
			unless document
				document = new Document(documentId)
				nowpad.documents.add(document)

			# Attempt document unlock and send result back to client
			if callback then callback document.unlock(@now.clientId)
		
		# Log
		everyone.now.log = ->
			console.log(
				clientClient: nowpad.clientCount
				clients: nowpad.clients
				documents: nowpad.documents
			)
		
		# A document is preparing for sync
		everyone.now.valueSyncDocument = (documentId, callback) ->
			# Fetch document
			document = nowpad.documents.get documentId
			unless document
				document = new Document(documentId)
				nowpad.documents.add(document)
			
			# Fetch values
			state = document.state
			value = document.value
			delay = document.delay

			# Send back
			callback state, value, delay

			# Log
			console.log 'Valuing', @now.clientId, 'for document', documentId
		
		# Sync
		everyone.now.patchSyncDocument = (documentId,clientState,patch,callback) ->
			# Fetch document
			document = nowpad.documents.get documentId
			unless document
				document = new Document(documentId)
				nowpad.documents.add(document)
			
			# Prepare
			stateQueue = []
			document.state = document.state || 0

			# Log
			console.log 'Syncing', @now.clientId, 'for document', documentId

			# Update Client
			if clientState isnt document.state
				# Requires Updates
				console.log 'Syncing:', @now.clientId, 'from', clientState, 'to', nowpad.documentState

				# Add patches
				stateQueue = document.states.slice clientState
			
			# Update Server
			if patch
				# Update
				document.state++

				# Log
				console.log 'Received patch:', @now.clientId, 'from', clientState, 'to', document.state

				# State
				State =
					id: document.state
					patch: patch
					cleintId: @now.clientId
				
				# Add
				stateQueue.push State
				document.states.push State

				# Apply
				result = nowpadCommon.applyPatch patch, document.value
				document.value = result.value
			
			# Return updates to client
			callback(stateQueue,document.state)
			
			# Notify other clients
			if patch
				# Notify nowpad clients
				everyone.now.syncNotify document.state

				# Notify application
				nowpad.trigger 'sync', [document.id, document.value, document.state]
	
	# Bind
	bind: (event,callback) ->
		if typeof nowpad.events[event] is 'undefined'
			throw new Error 'Unauthorised event: '+event
		else
			nowpad.events[event].push callback
	
	# Trigger
	trigger: (event,args) ->
		nowpad.events[event].forEach (callback) ->
			callback.apply(callback,args)

# Initialise
nowpad.init()

# Export
module.exports = nowpad
