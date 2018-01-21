﻿/*
 * Server demo.
 * Listens for incoming connections on port 2525.
 * Accepts any connection.
 * Any message recieved will be sent back (echo-ed).
 */
module server;

version(serverdemo){
	import networkd;
	import std.stdio;
	
	void main(){
		Node server = new Node(true, 2525);
		while (true){
			NetEvent event = server.getEvent();
			if (event.type == NetEvent.Type.MessageEvent){
				uint senderID = cast(uint)event.conID;
				char[] message = event.getEventData!(NetEvent.Type.MessageEvent);
				writeln("Message received from ID#",senderID,':');
				writeln(message);
				server.sendMessage(senderID, cast(char[])"Server: "~message);
			}else if (event.type == NetEvent.Type.ConnectionAccepted){
				writeln("New connection accepted. ConnectionID:",event.conID);
			}
		}
	}
}