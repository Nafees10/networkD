# networkD
A simple and basic networking library based on `std.socket` for D Language

---

All it does/adds is:
1. event-based networking
2. Managing connections - assigns each connection/socket an "ID".
3. Listening for new connections on a specific port
4. Send/receive messages with a max-size limit of `4294967292 bytes` (4 bytes less than 4 gigabytes)  
  
---

For documentation; the whole code is commented well enough.
