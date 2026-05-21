const http = require('http');

function disableTimeouts(server) {
  server.timeout = 0;
  server.requestTimeout = 0;
  server.headersTimeout = 0;
  server.keepAliveTimeout = 0;
  server.setTimeout(0);
  return server;
}

const originalCreateServer = http.createServer;

http.createServer = function createServerWithoutTimeouts(...args) {
  const server = disableTimeouts(originalCreateServer.apply(this, args));
  server.on('request', (req, res) => {
    req.setTimeout(0);
    res.setTimeout(0);
  });
  return server;
};
