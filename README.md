# Now Playing - Multi-tenant Music Dashboard

Real-time music dashboard supporting Spotify and Sonos with public/private sharing.

## 🏗️ Architecture

- **Backend**: Python/Flask with Socket.IO
- **Frontend**: React/TypeScript
- **Database**: PostgreSQL 15
- **Auth**: Google OAuth + Spotify OAuth

## 🚀 Quick Start

### 1. Start Database

```bash
cd docker
./start.sh
```

This will:
- Start PostgreSQL in Docker
- Auto-initialize schema (if `INIT_SCHEMA=true` in `.env`)
- Make database available on `localhost:5432`

### 2. Verify Database

```bash
# Connect to PostgreSQL shell
./psql.sh

# Check tables
\dt

# Query users
SELECT * FROM users;

# Exit
\q
```

### 3. Manual Schema Initialization (if needed)

If you set `INIT_SCHEMA=false` in `.env`:

```bash
./init-schema.sh
```

## 📁 Project Structure

```
media-display/
├── old/                    # Legacy code (preserved)
├── docker/                 # Docker configs & scripts
│   ├── docker-compose.yml
│   ├── .env                # Docker environment config
│   ├── .env.example        # Docker config template
│   ├── start.sh           # Start services
│   ├── stop.sh            # Stop services
│   ├── init-schema.sh     # Initialize schema
│   ├── reset-db.sh        # Reset database
│   └── psql.sh            # Quick PostgreSQL access
├── database/
│   └── schema.sql         # Database schema
├── server/                # Backend (coming next)
│   ├── .env               # Server environment config
│   ├── .env.example       # Server config template
│   └── ...
├── client/                # Frontend (coming next)
└── README.md
```

## 🗄️ Database

**Connection Details:**
- Host: `localhost`
- Port: `5432`
- Database: `nowplaying`
- User: `nowplaying` (configurable in `.env`)
- Password: See `docker/.env`

**Tables:**
- `users` - User accounts (Google OAuth)
- `spotify_tokens` - Spotify OAuth tokens per user
- `dashboard_settings` - User dashboard preferences
- `active_sessions` - WebSocket connection tracking
- `track_history` - Listening history (optional analytics)

## 🛠️ Development

### Database Management

```bash
# Start database
cd docker && ./start.sh

# Stop database
./stop.sh

# Reset database (⚠️  deletes all data)
./reset-db.sh

# Access PostgreSQL shell
./psql.sh

# View logs
docker-compose logs -f postgres
```

### Optional: pgAdmin

To start pgAdmin web interface:

```bash
docker-compose --profile tools up -d pgadmin
```

Access at: http://localhost:5050
- Email: `admin@nowplaying.local`
- Password: `admin`

## 📝 Next Steps

### Phase 1 (Current)
- ✅ Project structure
- ✅ Docker Compose setup
- ✅ Database schema
- 🚧 Backend foundation (next)

### Phase 2
- Google OAuth
- Spotify OAuth
- JWT authentication

### Phase 3
- WebSocket server
- Session management

### Phase 4+
- Frontend client
- Spotify Web SDK integration
- Sonos local discovery
- Public dashboards

## 🔧 Configuration

### Environment Files (All Gitignored)

**1. Docker Environment** (`docker/.env`):
```bash
# Copy from template
cp docker/.env.example docker/.env

# Database credentials
POSTGRES_USER=nowplaying
POSTGRES_PASSWORD=nowplaying_dev_password
POSTGRES_DB=nowplaying

# Auto-initialize schema on first run
INIT_SCHEMA=true

# pgAdmin (optional)
PGADMIN_EMAIL=admin@nowplaying.local
PGADMIN_PASSWORD=admin
```

**2. Server Environment** (`server/.env`):
```bash
# Copy from template
cp server/.env.example server/.env

# Edit server/.env with your values:
# - OAuth credentials (Google, Spotify)
# - Database connection (should match docker/.env)
# - Server settings (host, port, debug)
# - Logging levels
```

**Note:** Each component has its own `.env` file for complete independence:
- `docker/.env` - PostgreSQL and Docker services
- `server/.env` - Python backend application

## 📚 Documentation

- [Database Schema](database/schema.sql)
- [Docker Compose](docker/docker-compose.yml)
- [Legacy Code](old/) - Previous implementation (preserved)

## 🐛 Troubleshooting

### Database won't start
```bash
# Check logs
cd docker
docker-compose logs postgres

# Verify port is available
lsof -i :5432
```

### Schema not applied
```bash
# Manually apply schema
cd docker
./init-schema.sh
```

### Reset everything
```bash
cd docker
./stop.sh
docker-compose down -v  # Remove volumes
./start.sh
```

## 📄 License

MIT
