module networkd;

import std.socket;
import utils.misc;
import utils.baseconv;//needed for converting message size to array of char
import utils.lists;

/// Used by `Node` to store incoming message's contents and size
private struct IncomingMessage{
	char[] buffer; /// The recieved message
	uint size = 0;/// The size of the message, we use uint instead of uinteger because the size can not be more than 2^32 bytes
}

/// Used by `Node` to store message that has been recieved, and is still in the stack, yet to be read
private struct RecievedMessage{
	char[] message; /// The recieved message, size can be determined by array's length
	uinteger senderConID; /// Connection ID of the sender
}

/// Stores message status, i.e: total size, and recieved size
public struct IncomingMessageStatus{
	uinteger size, recieved;
}

class Node{
private:
	InternetAddress listenerAddr;
	Socket listener;/// To recieve incoming connections
	Socket[] connections;/// List of all connected Sockets
	bool isAcceptingConnections = false;/// Determines whether any new incoming connection will be accepted or not

	bool recieveLoopIsRunning;// used to terminate recieveLoop by setting it's val to false

	LinkedList!RecievedMessage recievedMessages;/// recieved messages are stored here, till they're read
	IncomingMessage[uinteger] incomingMessages;/// messages that are not completely recieved yet, i.e only a part has been recieved, are stored here

	///Called by `Node.recieveLoop` when a new message is recieved, with `buffer` containing the message, and `conID` as the 
	///connection ID
	void addRecievedMessage(char[] buffer, uinteger conID){
		// check if the firt part of the message was already recieved
		if (conID in incomingMessages){
			// append this packet's content to previously recieved message(s)
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
			// check if size has bee recieved
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
			// transfer complete, move it to `recievedMessages`
			RecievedMessage msg;
			msg.senderConID = conID;
			msg.message = incomingMessages[conID].buffer[4 .. incomingMessages[conID].size];
			// adding to `recievedMessages`
			recievedMessages.append(msg);
			// remove it from `incomingMessages`
			incomingMessages.remove(conID);
			// check if there were extra bytes, if yes, recursively call itself
			if (otherMessage != null){
				addRecievedMessage(otherMessage, conID);
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
		recievedMessages = new LinkedList!RecievedMessage;
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
		recievedMessages.destroy();
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
		if (connections[i] is null){
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
	/// The message on the other end must be recieved using `networkd.Node` because before sending, the message is not sent raw.
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
				msgSize.length = 4;
				msgSize[4 - oldLength .. 4] = msgSize[0 .. oldLength];
				//fill 0x00 in empty space
				msgSize[0 .. (4 - oldLength) - 1] = cast(char)0;
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
	/// Without this running, no new messages will be added to stack, i.e messages wont be recieved
	void recieveLoop(){
		// create a SocketSet
		SocketSet readSet = new SocketSet();

		TimeVal timeout;
		timeout.seconds = 5;// after every 5 sec, check if loop needs to terminate

		char[1024] buffer;

		recieveLoopIsRunning = true;
		while(recieveLoopIsRunning){
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
			// check if a message was recieved
			if (Socket.select(readSet, null, null, &timeout) > 0){
				// check if a new connection needs to be accepted
				if (readSet.isSet(listener)){
					// add new connection
					Socket client = listener.accept();
					client.setOption(SocketOptionLevel.TCP, SocketOption.KEEPALIVE, 1);
					connections ~= client;
				}
				// check if a message was recieved
				for (uinteger conID = 0; conID < connections.length; conID ++){
					//did this connection sent it?
					if (readSet.isSet(connections[conID])){
						uinteger msgLen = connections[conID].receive(buffer);
						// check if connection was closed
						if (msgLen == 0){
							// connection closed, remove from array, and clear any partially-recieved message from this connection
							connections[conID].destroy();
							connections[conID] = null;
							// remove messages
							if (conID in incomingMessages){
								incomingMessages.remove(conID);
							}
						}else{
							// a message was recieved
							addRecievedMessage(buffer[0 .. msgLen], conID);
						}
					}
				}
			}
		}

	}
	/// Terminates the message-recieving-loop. This function will return immediately but the loop can take up to 5 seconds to 
	/// actually terminate
	/// 
	/// Returns true if the loop was running and was was marked to terminate
	/// faslse if the loop wasn't running
	bool terminateRecieveLoop(){
		if (recieveLoopIsRunning){
			recieveLoopIsRunning = false;
			return true;
		}else{
			return false;
		}
	}

	/// Returns a message recieved from a connection using connection ID.
	/// Returns null or zero length in case there are no messages
	char[] getMessage(uinteger conID){
		//go through the linked list to check if there's any message from conID
		recievedMessages.resetRead();
		RecievedMessage* msg = recievedMessages.read();
		char[] r = null;
		while (msg !is null){
			if ((*msg).senderConID == conID){
				//return and delete this message, from list
				r = (*msg).message;
				//delete from list
				if (recievedMessages.removeLastRead() == false){
					throw new Exception("Failed to remove message from `recievedMessages` LinkedList");
				}
			}
		}
		return r;
	}

	/// Returns `IncomingMessageStatus` from a message from a connection using connection ID
	/// If there is no message being recieved, or connection ID is invalid, the size returned will be zero
	/// 
	/// A note: The total message size will be 4 bytes more than that of the message that will be actually returned by `getMessage`
	/// This is because with every message, 4 extra bytes are sent that contain the message size
	IncomingMessageStatus getIncomingMessageStatus(uinteger conID){
		IncomingMessageStatus status;
		//check if id is valid and a message is being recieved
		if (connectionExists(conID) && conID in incomingMessages){
			status.size = incomingMessages[conID].size;
			status.recieved = incomingMessages[conID].buffer.length;

		}else{
			status.size = 0;
		}
		return status;
	}

	/// Clears all stored recieved messages from all connections
	void clearRecievedMessages(){
		recievedMessages.clear();
	}
	/// Clears all stored recieved messages from a connection using the connection ID
	void clearRecievedMessages(uinteger conID){
		// will have to go through list
		recievedMessages.resetRead();
		RecievedMessage* msg = recievedMessages.read();

		while (msg !is null){
			if ((*msg).senderConID == conID){
				if (recievedMessages.removeLastRead() == false){
					throw new Exception("Failed to remove message from `recievedMessages` LinkedList");
				}
			}
		}
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
}