module networkd;

import std.socket;
import utils.misc;

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
	bool newConnection(string address, ushort port){
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
			i = connections.length;
			connections ~= connection;
		}
		return i;
	}
	/// Sends a message to a Node using connection ID
	bool sendMessage(uinteger conID, char[] message){

	}
}