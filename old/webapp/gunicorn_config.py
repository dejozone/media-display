"""
Gunicorn configuration for webapp static file serving
"""
import os
import multiprocessing

# Server socket
bind = f"{os.getenv('WEBAPP_HOST', '0.0.0.0')}:{os.getenv('WEBAPP_PORT', '8080')}"

# Worker processes - can use more workers for static files
workers = int(os.getenv('GUNICORN_WORKERS', str(multiprocessing.cpu_count() * 2 + 1)))
worker_class = 'sync'  # sync worker is fine for static files
worker_connections = int(os.getenv('GUNICORN_WORKER_CONNECTIONS', '1000'))

# Restart workers after this many requests (helps prevent memory leaks)
max_requests = int(os.getenv('GUNICORN_MAX_REQUESTS', '10000'))
max_requests_jitter = int(os.getenv('GUNICORN_MAX_REQUESTS_JITTER', '1000'))

# Timeout
timeout = int(os.getenv('GUNICORN_TIMEOUT', '30'))  # Static files shouldn't take long
graceful_timeout = int(os.getenv('GUNICORN_GRACEFUL_TIMEOUT', '30'))
keepalive = int(os.getenv('GUNICORN_KEEPALIVE', '5'))

# Logging
accesslog = os.getenv('GUNICORN_ACCESS_LOG', '-')  # '-' means stdout
errorlog = os.getenv('GUNICORN_ERROR_LOG', '-')    # '-' means stderr
loglevel = os.getenv('GUNICORN_LOG_LEVEL', 'info')
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)s'

# Process naming
proc_name = 'media-display-webapp'

# Server mechanics
daemon = False
pidfile = None
umask = 0
user = None
group = None
tmp_upload_dir = None

def post_fork(server, worker):
    """Called just after a worker has been forked."""
    server.log.info("Worker spawned (pid: %s)", worker.pid)

def pre_fork(server, worker):
    """Called just prior to forking the worker subprocess."""
    pass

def pre_exec(server):
    """Called just prior to forking off a secondary master process during things like config reloading."""
    server.log.info("Forked child, re-executing.")

def when_ready(server):
    """Called just after the server is started."""
    server.log.info("Server is ready. Spawning workers")

def worker_int(worker):
    """Called when a worker receives the SIGINT or SIGQUIT signal."""
    worker.log.info("Worker received INT or QUIT signal")

def worker_abort(worker):
    """Called when a worker receives the SIGABRT signal."""
    worker.log.info("Worker received SIGABRT signal")
