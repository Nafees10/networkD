module networkd;

import std.socket;
import utils.misc;
import utils.baseconv;//needed for converting message size to array of char
import utils.lists;

/// Used by `Node` to store messages that aren't completely received, temporarily
private struct IncomingMessage{
	char[] buffer; /// The received message
	uint size = 0; /// The size of the message, we use uint instead of uinteger because the size can not be more than 2^32 bytes
}


/// Stores data about the NetEvent returned by `Node.getEvent`
struct NetEvent{
	/// Enum defining all possible NetEvent types
	enum Type{
		MessageEvent, /// When a message has been completely transfered (received)
		PartMessageEvent, /// When a part of a message is received. This can be used to estimate the time-left...
		ConnectionAccepted, /// When the listener accepts an incoming connection. The connection ID of this connection can be retrieved by `NetEvent.conID`
		ConnectionClosed, /// When a connection is closed
		Timeout, /// Nothing happened, `Node.getEvent` exited because of timeout
	}
	/// PartMessageEvent, returned by `NetEvent.getEventData!(NetEvent.Type.PartMessageEvent)`
	/// Stores information about transmission of a message, which isn't completely received yet.
	/// 
	/// The values provided can be (will be) incorrect if less than 4 bytes have been received
	struct PartMessageEvent{
		uint received; /// The number of bytes that have been received
		uint size; /// The length of message when transfer will be complete
	}
	private Type _type;
	private uinteger senderConID;
	private union{
		char[] messageEvent;
		PartMessageEvent partMessageEvent;
	}

	/// Returns the Type for this Event
	@property Type type(){
		return _type;
	}
	/// Returns the connection ID associated with the NetEvent
	@property uinteger conID(){
		return senderConID;
	}
	/// Returns more data on the NetEvent, for each NetEvent Type, the returned data type(s) is different
	/// Call it like:
	/// ```
	/// NetEvent.getEventData!(NetEvent.Type.SOMETYPE);
	/// ```
	/// 
	/// For `NetEvent.Type.MessageEvent`, the message received is returned as `char[]`
	/// For `NetEvent.Type.partMessageEvent`, `partMessageEvent` is returned which contains `received` bytes, and `size`
	/// For `NetEvent.Type.ConnectionAccepted` and `...ConnectionClosed`, no data is returned, exception will be thrown instead.
	@property auto getEventData(Type T)(){
		// make sure that the type is correct
		//since it's a template, and Type T will be known at compile time, we'll use static
		if (T != type){
			throw new Exception("Provided NetEvent Type differs from actual NetEvent Type");
		}
		// now a static if for every type...
		static if (T == Type.MessageEvent){
			return messageEvent;
		}else static if (T == Type.PartMessageEvent){
			return partMessageEvent;
		}else static if (T == Type.ConnectionAccepted){
			throw new Exception("No further data can be retrieved from NetEvent.Type.ConnectionAccepted using NetEvent.getEventData");
		}else static if (T == Type.ConnectionClosed){
			throw new Exception("No further data can be retrieved from NetEvent.Type.ConnectionClosed using NetEvent.getEventData");
		}
	}
	//constructors, different for each NetEvent Type
	// we'll mark them private as all NetEvents are constructed in this module
	private{
		this(uinteger conID, char[] eventData){
			messageEvent = eventData.dup;
			_type = Type.MessageEvent;
			senderConID = conID;
		}
		this(uinteger conID, PartMessageEvent eventData){
			partMessageEvent = eventData;
			_type = Type.PartMessageEvent;
			senderConID = conID;
		}
		this(uinteger conID, Type t){
			_type = t;
			senderConID = conID;
		}
	}
}

class Node{
private:
	InternetAddress listenerAddr;
	Socket listener;/// To receive incoming connections
	Socket[] connections;/// List of all connected Sockets
	bool isAcceptingConnections = false;/// Determines whether any new incoming connection will be accepted or not


	
	IncomingMessage[uinteger] incomingMessages;/// messages that are not completely received yet, i.e only a part has been received, are stored here

	SocketSet receiveSockets;

	///Called by `Node.getEvent` when a new message is received, with `buffer` containing the message, and `conID` as the 
	///connection ID
	NetEvent addReceivedMessage(char[] buffer, uinteger conID){
		// check if the firt part of the message was already received
		if (conID in incomingMessages){
			// append this packet's content to previously received message(s)
			incomingMessages[conID].buffer ~= buffer;
			// check if the total size is known
			if (incomingMessages[conID].size == 0){
				// no, size not yet known, calculate it
				if (incomingMessages[conID].buffer.length >= 4){
					// size can be calculated, do it now
					incomingMessages[conID].size = cast(uint)charToDenary(incomingMessages[conID].buffer[0 .. 4].dup);
					// the first 4 bytes will be removed when transfer is complete, so no need t odo it now
				}
			}
		}else{
			// this is the first message in this transfer, so make space in `incomingMessages`
			IncomingMessage msg;
			msg.buffer = buffer;
			// check if size has bee received
			if (msg.buffer.length >= 4){
				msg.size = cast(uint)charToDenary(msg.buffer[0 .. 4].dup);
			}
			// add it to `incomingMessages`
			incomingMessages[conID] = msg;
		}
		NetEvent result;
		// check if transfer is complete, case yes, add an NetEvent for it as complete message, else; as part message
		if (incomingMessages[conID].size > 0 && incomingMessages[conID].buffer.length >= incomingMessages[conID].size){
			// check if extra bytes were sent, consider those bytes as a separate message
			char[] otherMessage = null;
			if (incomingMessages[conID].buffer.length > incomingMessages[conID].size){
				otherMessage = incomingMessages[conID].buffer
					[incomingMessages[conID].size .. incomingMessages[conID].buffer.length].dup;

				incomingMessages[conID].buffer.length = incomingMessages[conID].size;
			}
			// transfer complete, move it to `receivedMessages`
			result = NetEvent(conID, incomingMessages[conID].buffer[4 .. incomingMessages[conID].size]);
			// remove it from `incomingMessages`
			incomingMessages.remove(conID);

			// check if there were extra bytes, if yes, recursively call itself
			if (otherMessage != null){
				addReceivedMessage(otherMessage, conID);
			}
		}else{
			//add NetEvent for part message
			NetEvent.PartMessageEvent partMessage;
			if (incomingMessages[conID].buffer.length > 4){
				partMessage.received = cast(uint)incomingMessages[conID].buffer.length - 4;
			}else{
				partMessage.received = 0;
			}
			partMessage.size = incomingMessages[conID].size - 4;
			result = NetEvent(conID, partMessage);
		}
		return result;
	}

	/// Adds socket to `connections` array, returns connection ID
	uinteger addSocket(Socket connection){
		// add it to list
		//go through the list to find a free id, if none, expand the array
		uinteger i;
		for (i = 0; i < connections.length; i++){
			if (connections[i] is null){
				break;
			}
		}
		// check if has to expand array
		if (connections.length > 0 && i < connections.length && connections[i] is null){
			// there's space already, no need to expand
			connections[i] = connection;
		}else{
			// in case of no space, append it to end of array
			i = connections.length;
			connections ~= connection;
		}
		return i;
	}


public:
	/// `listenForConnections` if true enables the listener, and any incoming connections are accepted  
	/// `port` determines the port on which the listener will run
	this(bool listenForConections=false, ushort port=2525){
		if (listenForConections){
			listenerAddr = new InternetAddress(port);
			listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
			listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
			listener.bind(listenerAddr);
			listener.listen(15);
			isAcceptingConnections = true;
		}else{
			listenerAddr = null;
			listener = null;
		}
		receiveSockets = new SocketSet;
	}
	/// Closes all connections, including the listener, and destroys the Node
	~this(){
		closeAllConnections();
		// stop the listener too
		if (listener !is null){
			listener.shutdown(SocketShutdown.BOTH);
			listener.close();
			destroy(listener);
			destroy(listenerAddr);
		}
		receiveSockets.destroy;
	}
	/// Closes all connections
	void closeAllConnections(){
		foreach(connection; connections){
			if (connection !is null){
				connection.shutdown(SocketShutdown.BOTH);
				connection.close();
				destroy(connection);
			}
		}
		connections.length = 0;
	}
	/// Creates a new connection to `address` using the `port`.
	/// address can either be an IPv4 ip address or a host name
	/// Returns the conection ID for the new connection if successful, throws exception on failure
	uinteger newConnection(string address, ushort port){
		InternetAddress addr = new InternetAddress(address, port);
		Socket connection = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
		try{
			connection.connect(addr);
		}catch (Exception e){
			throw e;
		}

		return addSocket(connection);
	}
	/// Closes a connection using it's connection ID
	/// Returns true on success, false on failure
	bool closeConnection(uinteger conID){
		if (connectionExists(conID)){
			connections[conID].shutdown(SocketShutdown.BOTH);
			connections[conID].close;
			destroy(connections[conID]);
			// mark it as 'free-slot'. because if we remove it, some connections might change their index.
			connections[conID] = null;
			// if it's at end, remove it as it's safe to do so
			if (conID+1 == connections.length){
				connections.length --;
			}
			return true;
		}else{
			return false;
		}
	}

	/// Returns true if a connection ID is assigned to an existing connection
	bool connectionExists(uinteger conID){
		bool r = false;
		if (conID < connections.length && connections[conID] !is null){
			r = true;
		}
		return r;
	}
	/// Sends a message to a Node using connection ID
	/// The message on the other end must be received using `networkd.Node.getEvent` because before sending, the message is not sent raw.
	/// The first 4 bytes (32 bits) contain the size of the message, including these 4 bytes
	/// This is followed by the content of the message. If the content is too large, it is split up into several packets.
	/// The max message size is 4 bytes less than 4 gigabytes (4294967292 bytes)
	/// 
	/// Returns true on success and false on failure
	bool sendMessage(uinteger conID, char[] message){
		bool r = false;
		//check if connection ID is valid
		if (connectionExists(conID)){
			char[] msgSize;
			uinteger size = message.length + 4;//+4 for the size-chars
			msgSize = denaryToChar(size);
			// make it take 4 bytes
			if (msgSize.length < 4){
				// fill the empty bytes with 0x00 to make it 4 bytes long
				uinteger oldLength = msgSize.length;
				char[] nSize;
				nSize.length = 4;
				nSize[] = 0;
				nSize[4 - oldLength .. 4] = msgSize.dup;
				msgSize = nSize;
			}
			/// only continue if size can fit in 4 bytes
			if (msgSize.length == 4){
				r = true;
				//insert size in message
				message = msgSize~message;
				//send it away, 1024 bytes at a time
				for (uinteger i = 0; i < message.length; i += 1024){
					// check if remaining message is less than 1024 bytes
					char[] toSend;
					if (message.length < i+1024){
						//then just send the remaining message
						toSend = message[i .. message.length].dup;
					}else{
						toSend = message[i .. i + 1024].dup;
					}
					/// now actually send it, and return false case of error
					if (connections[conID].send(toSend) == Socket.ERROR){
						r = false;
						break;
					}
				}
			}
		}
		return r;
	}
	///Waits for an NetEvent to occur, and returns it. A timeout can be provided, if null, max value is used
	///
	///Messages are not received till this function is called
	///
	///An NetEvent is either of these:
	///1. data received
	///2. connection accepted by listener
	///3. connection closed
	///4. timeout while waiting for the above to occur
	///
	///Returns: array containing events, or empty array in case of timeout or interruption
	NetEvent[] getEvent(TimeVal* timeout = null){
		char[1024] buffer;
		receiveSockets.reset;
		//add all active connections
		foreach(conn; connections){
			if (conn !is null){
				receiveSockets.add(conn);
			}
		}
		//add the listener if not null
		if (listener !is null){
			receiveSockets.add(listener);
		}
		// copy the timeout, coz idk why SocketSet.select resets it every time it timeouts
		TimeVal originalTimeout = *timeout;
		// check if a message was received
		int modifiedCount = Socket.select(receiveSockets, null, null, &originalTimeout);
		if (modifiedCount > 0){
			NetEvent[] result;
			result.length = cast(uinteger)modifiedCount;
			uinteger i;// the index of result to write to, next
			// check if a new connection needs to be accepted
			if (isAcceptingConnections && listener !is null && receiveSockets.isSet(listener)){
				// add new connection
				Socket client = listener.accept();
				client.setOption(SocketOptionLevel.TCP, SocketOption.KEEPALIVE, 1);
				uinteger conID = addSocket(client);

				result[i] = NetEvent(conID, NetEvent.Type.ConnectionAccepted);
				i++;
			}
			// check if a message was received
			for (uinteger conID = 0; conID < connections.length && i < result.length; conID ++){
				//did this connection sent it?
				if (receiveSockets.isSet(connections[conID])){
					uinteger msgLen = connections[conID].receive(buffer);
					// check if connection was closed
					if (msgLen == 0){
						// connection closed, remove from array, and clear any partially-received message from this connection
						connections[conID].destroy();
						connections[conID] = null;
						// remove messages
						if (conID in incomingMessages){
							incomingMessages.remove(conID);
						}

						result[i] = NetEvent(conID, NetEvent.Type.ConnectionClosed);
						i++;
					}else{
						// a message was received
						result[i] = addReceivedMessage(buffer[0 .. msgLen], conID);
						i++;
					}
				}
			}
			return result;
		}
		return [];
	}

	///Returns IP Address of a connection using connection ID
	///`local` if true, makes it return the local address, otherwise, remoteAddress is used
	///If connection doesn't exist, null is retured
	string getIPAddr(uinteger conID, bool local){
		//check if connection exists
		if (connectionExists(conID)){
			Address addr;
			if (local){
				addr = connections[conID].localAddress;
			}else{
				addr = connections[conID].remoteAddress;
			}
			return addr.toAddrString;
		}else{
			return null;
		}
	}
	/// Returns Host name of a connection using connection ID
	/// `local` if true, makes it return local host name, else, remote host name is used
	///If connection doesn't exist, null is retured
	string getHostName(uinteger conID, bool local){
		// check if valid connection
		if (connectionExists(conID)){
			Address addr;
			if (local){
				addr = connections[conID].localAddress;
			}else{
				addr = connections[conID].remoteAddress;
			}
			return addr.toHostNameString;
		}else{
			return null;
		}
	}
	/// Returns a list of all connection IDs that are currently assigned to connections, useful for running server
	/// 
	/// More information on connection can be retrieved using 
	uinteger[] getConnections(){
		LinkedList!uinteger list = new LinkedList!uinteger;
		for (uinteger i = 0; i < connections.length; i ++){
			if (connections[i] !is null){
				list.append(i);
			}
		}
		uinteger[] r = list.toArray;
		list.destroy;
		return r;
	}
	/// Specifies if incoming connections will be accepted by listener.
	/// It's value does not have any affect if `litenForConnections` was specified as `false` in constructor
	@property bool acceptConnections(){
		return isAcceptingConnections;
	}
	/// Specifies if incoming connections will be accepted by listener.
	/// It's value does not have any affect if `litenForConnections` was specified as `false` in constructor
	@property bool acceptConnections(bool newVal){
		return isAcceptingConnections = newVal;
	}
}


/// runs a loop waiting for events to occur, and calling a event-handler, while `isRunning == true`
/// 
/// `node` is the Node to run the loop for
/// `eventHandler` is the function to call when any event occurs
/// `isRunning` is the variable that specifies if the loop is still running, it can be terminated using `isRunning=false`
void runNetLoop(Node node, void function(NetEvent) eventHandler, ref shared(bool) isRunning){
	TimeVal timeout;
	timeout.seconds = 2;
	while(isRunning){
		NetEvent[] events = node.getEvent(&timeout);
		foreach (event; events){
			eventHandler(event);
		}
	}
}