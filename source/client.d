﻿/*
 * Client demo.
 * Connects to server in demo/server.d to port 2525
 * Reads line from stdin, sends to server, outputs messages received to stdout
 */

module client;

version(clientdemo){
	import networkd;
	import std.stdio;
	
	void main(){
		Node client = new Node();
		// stores the ID of the connection with server
		uint serverConnectionID;
		// connect with server
		serverConnectionID = cast(uint)client.newConnection("localhost", 2525);
		// start sending each line, and write received message back
		bool isRunning = true;
		while (isRunning){
			string line = readln;
			// remove trailing \n:
			line.length --;
			// send
			bool sentOk = client.sendMessage(serverConnectionID, cast(char[])line);
			if (sentOk){
				writeln("message sent, waiting for reply...");
			}else{
				writeln("failed to send message to server");
				break;
			}
			// receive
			NetEvent[] events = client.getEvent();
			foreach (event; events){
				if (event.type == NetEvent.Type.MessageEvent){
					writeln(event.getEventData!(NetEvent.Type.MessageEvent));
				}else if (event.type == NetEvent.Type.ConnectionClosed){
					writeln("Server closed the connection");
					isRunning = false;
					break;
				}
			}
		}
	}
}