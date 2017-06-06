module networkd;

import std.socket;
import utils.misc;
import utils.baseconv;//needed for converting message size to array of char

class Node{
private:
	InternetAddress listenerAddr;
	Socket listener;/// To recieve incoming connections
	Socket[] connections;/// List of all connected Sockets
	bool isAcceptingConnections = false;/// Determines whether any new incoming connection will be accepted or not
public:
	/// `listenForConnections` if true enables the listener, and any incoming connections are accepted  
	/// `port` determines the port on which the listener will run
	this(bool listenForConections=false, ushort port=2525){
		if (listenForConections){
			listenerAddr = new InternetAddress(port);
			listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
			listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
			listener.bind(listenerAddr);
		}else{
			listenerAddr = null;
			listener = null;
		}
	}
	/// Closes all connections, including the listener, and destroys the Node
	~this(){
		closeAllConnections();
		listener.shutdown(SocketShutdown.BOTH);
		listener.close();
		destroy(listener);
		destroy(listenerAddr);
	}
	/// Closes all connections
	void closeAllConnections(){
		foreach(connection; connections){
			connection.shutdown(SocketShutdown.BOTH);
			connection.close();
			destroy(connection);
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
		if (conID < connections.length && connections[conID] !is null){
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
	/// Sends a message to a Node using connection ID
	/// The message on the other end must be recieved using `networkD.Node` because before sending, the message is sent 
	/// in a format.
	/// The first 4 bytes (32 bits) contain the size of the message, including these 4 bytes
	/// This is followed by the content of the message. If the content is too large, it is split up into several packets.
	/// The max message size is 4 gigabytes (4 * 2^30 bytes)
	/// 
	/// Returns true on success and false on failure
	bool sendMessage(uinteger conID, char[] message){
		bool r = false;
		//check if connection ID is valid
		if (conID < connections.length && connections[conID] !is null){
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
					/// now actually send it, and return false case error
					if (connections[conID].send(toSend) == Socket.ERROR){
						r = false;
						break;
					}
				}
			}
		}
		return r;
	}
}