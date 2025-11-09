var express = require('express'),
    async = require('async'),
    { Pool } = require('pg'),
    cookieParser = require('cookie-parser'),
    path = require('path'),
    app = express(),
    server = require('http').Server(app),
    io = require('socket.io')(server, {
      path: '/result/socket.io'
    });

var port = process.env.PORT || 4000;

io.on('connection', function (socket) {

  socket.emit('message', { text : 'Welcome!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// Build connection string from environment variables (for AWS RDS or local dev)
var POSTGRES_USER = process.env.POSTGRES_USER || 'postgres';
var POSTGRES_PASSWORD = process.env.POSTGRES_PASSWORD || 'postgres';
var POSTGRES_HOST = process.env.POSTGRES_HOST || 'db';
var POSTGRES_PORT = process.env.POSTGRES_PORT || '5432';
var POSTGRES_DB = process.env.POSTGRES_DB || 'postgres';

var connectionString = `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}`;
console.log(`Connecting to Postgres at ${POSTGRES_HOST}:${POSTGRES_PORT}`);

var pool = new Pool({
  connectionString: connectionString,
  ssl: {
    rejectUnauthorized: false
  }
});

async.retry(
  {times: 1000, interval: 1000},
  function(callback) {
    pool.connect(function(err, client, done) {
      if (err) {
        console.error("Waiting for db - Error:", err.message || err);
      }
      callback(err, client);
    });
  },
  function(err, client) {
    if (err) {
      return console.error("Giving up - Final error:", err.message || err);
    }
    console.log("Connected to db");
    getVotes(client);
  }
);

function getVotes(client) {
  client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function(err, result) {
    if (err) {
      console.error("Error performing query: " + err);
    } else {
      var votes = collectVotesFromResult(result);
      io.sockets.emit("scores", JSON.stringify(votes));
    }

    setTimeout(function() {getVotes(client) }, 1000);
  });
}

function collectVotesFromResult(result) {
  var votes = {a: 0, b: 0};

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

app.use(cookieParser());
app.use(express.urlencoded());

// Serve static assets for result UI under /result path for cleaner ingress.
// This allows all assets to be fetched via /result/... without enumerating individual paths.
// Serve all static assets for the result UI. Use explicit sub-mounts to avoid any ambiguity
// and allow us to confirm each category independently if needed.
app.use('/result/stylesheets', express.static(path.join(__dirname, 'views', 'stylesheets')));
app.use('/result', express.static(path.join(__dirname, 'views'), { index: false }));

// Redirect /result (no trailing slash) to /result/ so that relative paths with <base href="/result/"> resolve consistently.
app.get('/result', function (req, res, next) {
  if (req.path === '/result' && !/\/$/.test(req.originalUrl)) {
    return res.redirect(301, '/result/');
  }
  next();
});

app.get('/', function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

// Serve same scoreboard on /result so ALB path /result works.
// Serve the scoreboard index at /result/ (trailing slash) and /result/index.html
app.get(['/result/', '/result/index.html'], function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

server.listen(port, function () {
  var port = server.address().port;
  console.log('App running on port ' + port);
});
