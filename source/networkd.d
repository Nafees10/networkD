module networkd;

import std.socket;
import utils.misc;
import utils.baseconv;//needed for converting message size to array of char
import utils.lists;

/// Used by `Node` to store incoming message's contents and size
private struct IncomingMessage{
	char[] buffer; /// The received message
	uint size = 0; /// The size of the message, we use uint instead of uinteger because the size can not be more than 2^32 bytes
}

/// Used by `Node` to store message that has been received, and is still in the stack, yet to be read
private struct ReceivedMessage{
	char[] message; /// The received message, size can be determined by array's length
	uinteger senderConID; /// Connection ID of the sender
}

/// MessageEvent, returned by `Event.get!(Event.Type.MessageReceived)`
struct MessageEvent{
	char[] message; /// The message that was received
}
/// PartMessageEvent, returned by `Event.get!(Event.Type.PartMessageReceived)`
struct PartMessageEvent{
	char[] message; /// The message that has been received
	uint size; /// The length of message when transfer will be complete
}


///Event: this type can contain other event types, such as message-received etc.
///It's returned by `Node.getEvent`
struct Event{
	/// Enum defining all possible event types
	enum Type{
		MessageEvent, /// When a message has been completely transfered (received)
		PartMessageEvent, /// When a part of a message is received. This can be used to estimate the time-left...
		ConnectionAccepted, /// When the listener accepts an incoming connection. The connection ID of this connection can be retrieved by `Event.conID`
		ConnectionClosed, /// When a connection is closed
	}
	/// Stores Type for this Event
	private Type type;
	/// Stores Connection ID of the sender
	private uinteger senderConID;
	/// an Event can be only of a single type, so we use union to store that Type
	private union{
		MessageEvent messageEvent;
		PartMessageEvent partMessageEvent;
	}

	/// Returns the Type for this event
	@property Type eventType(){
		return type;
	}
	/// Returns the connection ID associated with the event
	@property uinteger conID(){
		return senderConID;
	}
	/// Returns the event using the Event.Type  
	/// Call it like:
	/// ```
	/// Event.getEvent!(Event.Type.SOMETYPE);
	/// ```
	@property getEvent(Type T)(){
		// make sure that the type is correct
		//since it's a template, and Type T will be known at compile time, we'll use static
		static if (T != type){
			throw new Exception("Provided Event Type differs from actual Event Type");
		}
		// now a static if for every type...
		static if (T == Type.MessageReceived){
			return messageReceived;
		}else static if (T == Type.ConnectionAccepted){
			return connectionAccepted;
		}else static if (T == Type.ConnectionClosed){
			return connectionClosed;
		}else static if (T == Type.PartMessageReceived){
			return partMessageReceived;
		}
	}
	//constructors, different for each Event Type
	// we'll mark them private as all Events are constructed in this module
	private{
		this(uinteger conID, MessageEvent event){
			messageEvent = event;
			type = Type.MessageEvent;
			senderConID = conID;
		}
		this(uinteger conID, PartMessageEvent event){
			partMessageEvent = event;
			type = Type.PartMessageEvent;
			senderConID = conID;
		}
		this(uinteger conID, Type t){
			type = t;
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

	bool receiveLoopIsRunning;// used to terminate receiveLoop by setting it's val to false

	LinkedList!ReceivedMessage receivedMessages;/// received messages are stored here, till they're read
	IncomingMessage[uinteger] incomingMessages;/// messages that are not completely received yet, i.e only a part has been received, are stored here

	///Called by `Node.receiveLoop` when a new message is received, with `buffer` containing the message, and `conID` as the 
	///connection ID
	void addreceivedMessage(char[] buffer, uinteger conID){
		// check if the firt part of the message was already received
		if (conID in incomingMessages){
			// append this packet's content to previously received message(s)
			incomingMessages[conID].buffer ~= buffer;
			// check if the total size is known
			if (incomingMessages[conID].size == 0){
				// no, size not yet known, calculate it
				if (incomingMessages[conID].buffer.length >= 4){
					// size can be calculated, do it now
					incomingMessages[conID].size = cast(uint)charToDenary(incomingMessages[conID].buffer[0 .. 4]);
					// the first 4 bytes will be removed when transfer is complete, so no need t odo it now
				}
			}
		}else{
			// this is the first message in this transfer, so make space in `incomingMessages`
			IncomingMessage msg;
			msg.buffer = buffer;
			// check if size has bee received
			if (msg.buffer.length >= 4){
				msg.size = cast(uint)charToDenary(msg.buffer[0 .. 4]);
			}
			// add it to `incomingMessages`
			incomingMessages[conID] = msg;
		}
		// check if transfer is complete
		if (incomingMessages[conID].size > 0 && incomingMessages[conID].buffer.length >= incomingMessages[conID].size){
			// check if extra bytes were sent, consider those bytes as a separate message
			char[] otherMessage = null;
			if (incomingMessages[conID].buffer.length > incomingMessages[conID].size){
				otherMessage = incomingMessages[conID].buffer
					[incomingMessages[conID].size .. incomingMessages[conID].buffer.length];

				incomingMessages[conID].buffer.length = incomingMessages[conID].size;
			}
			// transfer complete, move it to `receivedMessages`
			ReceivedMessage msg;
			msg.senderConID = conID;
			msg.message = incomingMessages[conID].buffer[4 .. incomingMessages[conID].size];
			// adding to `receivedMessages`
			receivedMessages.append(msg);
			// remove it from `incomingMessages`
			incomingMessages.remove(conID);
			// check if there were extra bytes, if yes, recursively call itself
			if (otherMessage != null){
				addreceivedMessage(otherMessage, conID);
			}
		}
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
		}else{
			listenerAddr = null;
			listener = null;
		}
		receivedMessages = new LinkedList!ReceivedMessage;
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
		// remove all stored messages
		receivedMessages.destroy();
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
		// add it to list
		//go through the list to find a free id, if none, expand the array
		uinteger i;
		for (i = 0; i < connections.length; i++){
			if (connections[i] is null){
				break;
			}
		}
		// check if has to expand array
		if (connections.length > 0 && connections[i] is null){
			// there's space already, no need to expand
			connections[i] = connection;
		}else{
			// in case of no space, append it to end of array
			i = connections.length;
			connections ~= connection;
		}
		return i;
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

	///Returns true if a connection ID is assigned to an existing connection
	bool connectionExists(uinteger conID){
		bool r = false;
		if (conID < connections.length && connections[conID] !is null){
			r = true;
		}
		return r;
	}
	/// Sends a message to a Node using connection ID
	/// The message on the other end must be received using `networkd.Node` because before sending, the message is not sent raw.
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
				nSize[4 - oldLength .. 4][] = msgSize;
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
						toSend = message[i .. message.length];
					}else{
						toSend = message[i .. i + 1024];
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

	/// Run this function in a background thread to recive messages, and, if enabled, accept new connections through listener
	/// Without this running, no new messages will be added to stack, i.e messages wont be received
	void receiveLoop(){
		// create a SocketSet
		SocketSet readSet = new SocketSet();

		TimeVal timeout;
		timeout.seconds = 5;// after every 5 sec, check if loop needs to terminate

		char[1024] buffer;

		receiveLoopIsRunning = true;
		while(receiveLoopIsRunning){
			readSet.reset();
			// add all connections, listener too, if possible
			foreach(conn; connections){
				if (conn !is null){
					readSet.add(conn);
				}
			}
			//listener
			if (listener !is null){
				readSet.add(listener);
			}
			// check if a message was received
			if (Socket.select(readSet, null, null, &timeout) > 0){
				// check if a new connection needs to be accepted
				if (readSet.isSet(listener)){
					// add new connection
					Socket client = listener.accept();
					client.setOption(SocketOptionLevel.TCP, SocketOption.KEEPALIVE, 1);
					connections ~= client;
				}
				// check if a message was received
				for (uinteger conID = 0; conID < connections.length; conID ++){
					//did this connection sent it?
					if (readSet.isSet(connections[conID])){
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
						}else{
							// a message was received
							addreceivedMessage(buffer[0 .. msgLen], conID);
						}
					}
				}
			}
		}

	}
	///Waits for an event to occur, and returns it. A timeout can be provided
	/// TODO

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
}