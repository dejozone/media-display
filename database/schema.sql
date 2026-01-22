-- =============================================================================
-- Now Playing Database Schema
-- PostgreSQL 15+
-- =============================================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- USERS TABLE
-- =============================================================================
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(50) UNIQUE NOT NULL,
    display_name VARCHAR(100),
    
    -- Timestamps
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for users
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_username ON users(username);

-- =============================================================================
-- IDENTITIES TABLE (maps provider ids to a single user_id)
-- =============================================================================
CREATE TABLE identities (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL,
    provider_id VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (provider, provider_id)
);

CREATE INDEX idx_identities_user_id ON identities(user_id);
CREATE INDEX idx_identities_provider_id ON identities(provider_id);

-- =============================================================================
-- AVATARS TABLE (manages user avatars from multiple sources)
-- =============================================================================
CREATE TABLE avatars (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    source VARCHAR(20) NOT NULL CHECK (source IN ('provider', 'upload', 'default')),
    provider_id VARCHAR(255) REFERENCES identities(provider_id) ON DELETE CASCADE,
    is_selected BOOLEAN NOT NULL DEFAULT FALSE,
    file_size INTEGER,
    mime_type VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Constraints
    UNIQUE (user_id, url),
    CHECK (
        (source = 'provider' AND provider_id IS NOT NULL) OR
        (source IN ('upload', 'default') AND provider_id IS NULL)
    )
);

-- Indexes for avatars
CREATE INDEX idx_avatars_user_id ON avatars(user_id);
CREATE INDEX idx_avatars_user_selected ON avatars(user_id, is_selected) WHERE is_selected = TRUE;
CREATE INDEX idx_avatars_provider_id ON avatars(provider_id);

-- =============================================================================
-- SPOTIFY TOKENS TABLE (keyed by user_id; spotify_id unique)
CREATE TABLE spotify_tokens (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    spotify_id VARCHAR(255) UNIQUE NOT NULL,
    access_token TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    token_expires_at BIGINT NOT NULL,
    scope TEXT,
    
    -- Timestamps
    connected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_refreshed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for spotify_tokens
CREATE INDEX idx_spotify_tokens_spotify_id ON spotify_tokens(spotify_id);
CREATE INDEX idx_spotify_tokens_expires_at ON spotify_tokens(token_expires_at);

-- =============================================================================
-- DASHBOARD SETTINGS TABLE
-- =============================================================================
CREATE TABLE dashboard_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    
    -- Visibility
    is_public BOOLEAN DEFAULT FALSE,
    custom_slug VARCHAR(50) UNIQUE,
    
    -- Display preferences
    theme VARCHAR(20) DEFAULT 'dark',
    show_album_art BOOLEAN DEFAULT TRUE,
    show_progress_bar BOOLEAN DEFAULT TRUE,
    
    -- Service preferences
    spotify_enabled BOOLEAN DEFAULT FALSE,
    sonos_enabled BOOLEAN DEFAULT FALSE,
    
    -- Timestamps
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for dashboard_settings
CREATE INDEX idx_dashboard_custom_slug ON dashboard_settings(custom_slug);
CREATE INDEX idx_dashboard_public ON dashboard_settings(is_public) WHERE is_public = TRUE;

-- =============================================================================
-- ACTIVE SESSIONS TABLE (for WebSocket tracking)
-- =============================================================================
CREATE TABLE active_sessions (
    socket_id VARCHAR(100) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_type VARCHAR(10) NOT NULL CHECK (session_type IN ('owner', 'viewer')),
    
    -- Timestamps
    connected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for active_sessions
CREATE INDEX idx_sessions_user_id ON active_sessions(user_id);
CREATE INDEX idx_sessions_last_activity ON active_sessions(last_activity);

-- =============================================================================
-- TRACK HISTORY TABLE (optional - for analytics)
-- =============================================================================
CREATE TABLE track_history (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source VARCHAR(10) NOT NULL CHECK (source IN ('spotify', 'sonos')),
    
    -- Track metadata
    track_id VARCHAR(255),
    track_name VARCHAR(500),
    artist_name VARCHAR(500),
    album_name VARCHAR(500),
    album_art_url TEXT,
    duration_ms INTEGER,
    
    -- Timestamp
    played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for track_history
CREATE INDEX idx_history_user_id ON track_history(user_id, played_at DESC);
CREATE INDEX idx_history_track_id ON track_history(track_id);
CREATE INDEX idx_history_played_at ON track_history(played_at DESC);

-- =============================================================================
-- TRIGGER: Auto-update updated_at timestamps
-- =============================================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Apply trigger to relevant tables
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_dashboard_settings_updated_at BEFORE UPDATE ON dashboard_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_avatars_updated_at BEFORE UPDATE ON avatars
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- INITIAL DATA (optional)
-- =============================================================================

-- Create a test user (for development only - remove in production)
-- INSERT INTO users (email, username, display_name, google_id)
-- VALUES (
--     'test@example.com',
--     'testuser',
--     'Test User',
--     'google_test_id_123'
-- );

-- =============================================================================
-- GRANTS (adjust for your security requirements)
-- =============================================================================

-- Grant permissions to application user
-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO nowplaying;
-- GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO nowplaying;

-- =============================================================================
-- SCHEMA VERSION
-- =============================================================================
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT
);

INSERT INTO schema_version (version, description)
VALUES (5, 'Added avatars table; removed is_selected from identities; avatars support provider, upload, and default sources');

-- =============================================================================
-- END OF SCHEMA
-- =============================================================================
