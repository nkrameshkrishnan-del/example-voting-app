from flask import Flask, render_template, request, make_response, g
from redis import Redis
import os
import socket
import random
import json
import logging

# Environment-driven Redis configuration (supports ElastiCache or local dev)
REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', '6379'))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD') or None
REDIS_SSL = os.getenv('REDIS_SSL', 'false').lower() in ('1', 'true', 'yes')

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

def get_redis():
    if not hasattr(g, 'redis'):
        redis_kwargs = {
            'host': REDIS_HOST,
            'port': REDIS_PORT,
            'db': 0,
            'socket_timeout': 5,
        }
        if REDIS_PASSWORD:
            redis_kwargs['password'] = REDIS_PASSWORD
        if REDIS_SSL:
            # For ElastiCache in-transit encryption
            redis_kwargs['ssl'] = True
        g.redis = Redis(**redis_kwargs)
        app.logger.info("Initialized Redis client host=%s port=%s ssl=%s", REDIS_HOST, REDIS_PORT, REDIS_SSL)
    return g.redis

@app.route("/", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None

    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        app.logger.info('Received vote for %s', vote)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)
