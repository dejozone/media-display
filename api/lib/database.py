#!/usr/bin/env python3
"""
Database Connection Layer
PostgreSQL connection management with context managers and helper methods
"""
import sys
from pathlib import Path

# Add server directory to Python path for imports
SERVER_DIR = Path(__file__).parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool
from contextlib import contextmanager
from typing import Dict, List, Optional, Any, Tuple
from config import Config
from lib.utils.logger import database_logger


class Database:
    """PostgreSQL database connection manager with connection pooling"""
    
    def __init__(
        self,
        database_url: Optional[str] = None,
        min_conn: int = 1,
        max_conn: int = 10
    ):
        """
        Initialize database connection pool
        
        Args:
            database_url: PostgreSQL connection URL
            min_conn: Minimum number of connections in pool
            max_conn: Maximum number of connections in pool
        """
        self.database_url = database_url or Config.DATABASE_URL
        self.pool: Optional[ThreadedConnectionPool] = None
        self.min_conn = min_conn
        self.max_conn = max_conn
        
        self.connect()
    
    def connect(self):
        """Establish database connection pool"""
        try:
            self.pool = ThreadedConnectionPool(
                self.min_conn,
                self.max_conn,
                self.database_url,
                cursor_factory=RealDictCursor
            )
            database_logger.info("✅ Database connection pool created")
            
            # Test connection
            with self.get_connection() as conn:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT version();")
                    version = cursor.fetchone()
                    database_logger.info(f"✅ PostgreSQL version: {version['version'].split(',')[0]}")
                    
        except Exception as e:
            database_logger.error(f"❌ Database connection failed: {e}")
            raise
    
    @contextmanager
    def get_connection(self):
        """
        Context manager for getting a connection from pool
        
        Usage:
            with db.get_connection() as conn:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT * FROM users")
        """
        if not self.pool:
            raise RuntimeError("Database connection pool not initialized")
        
        conn = None
        try:
            conn = self.pool.getconn()
            yield conn
        finally:
            if conn:
                self.pool.putconn(conn)
    
    @contextmanager
    def get_cursor(self, commit: bool = True):
        """
        Context manager for database cursor with automatic commit/rollback
        
        Args:
            commit: Whether to commit transaction on success
        
        Usage:
            with db.get_cursor() as cursor:
                cursor.execute("INSERT INTO users ...")
        """
        with self.get_connection() as conn:
            cursor = conn.cursor()
            try:
                yield cursor
                if commit:
                    conn.commit()
            except Exception as e:
                conn.rollback()
                database_logger.error(f"Database error: {e}")
                raise
            finally:
                cursor.close()
    
    def execute_one(self, query: str, params: Optional[Tuple] = None) -> Optional[Dict]:
        """
        Execute query and return one result
        
        Args:
            query: SQL query
            params: Query parameters
        
        Returns:
            Single row as dict or None
        """
        with self.get_cursor(commit=False) as cursor:
            cursor.execute(query, params)
            result = cursor.fetchone()
            return dict(result) if result else None
    
    def execute_many(self, query: str, params: Optional[Tuple] = None) -> List[Dict]:
        """
        Execute query and return all results
        
        Args:
            query: SQL query
            params: Query parameters
        
        Returns:
            List of rows as dicts
        """
        with self.get_cursor(commit=False) as cursor:
            cursor.execute(query, params)
            results = cursor.fetchall()
            return [dict(row) for row in results]
    
    def execute_write(self, query: str, params: Optional[Tuple] = None) -> int:
        """
        Execute write query (INSERT, UPDATE, DELETE)
        
        Args:
            query: SQL query
            params: Query parameters
        
        Returns:
            Number of affected rows
        """
        with self.get_cursor(commit=True) as cursor:
            cursor.execute(query, params)
            return cursor.rowcount
    
    def execute_insert_returning(self, query: str, params: Optional[Tuple] = None) -> Optional[Dict]:
        """
        Execute INSERT query with RETURNING clause
        
        Args:
            query: SQL INSERT query with RETURNING
            params: Query parameters
        
        Returns:
            Inserted row data
        """
        with self.get_cursor(commit=True) as cursor:
            cursor.execute(query, params)
            result = cursor.fetchone()
            return dict(result) if result else None
    
    def execute_batch(self, query: str, params_list: List[Tuple]) -> int:
        """
        Execute batch insert/update
        
        Args:
            query: SQL query
            params_list: List of parameter tuples
        
        Returns:
            Total number of affected rows
        """
        with self.get_cursor(commit=True) as cursor:
            total_rows = 0
            for params in params_list:
                cursor.execute(query, params)
                total_rows += cursor.rowcount
            return total_rows
    
    def table_exists(self, table_name: str) -> bool:
        """
        Check if table exists
        
        Args:
            table_name: Name of the table
        
        Returns:
            True if table exists
        """
        query = """
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_schema = 'public' 
                AND table_name = %s
            );
        """
        result = self.execute_one(query, (table_name,))
        return result['exists'] if result else False
    
    def get_table_count(self) -> int:
        """
        Get count of tables in public schema
        
        Returns:
            Number of tables
        """
        query = """
            SELECT COUNT(*) as count
            FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_type = 'BASE TABLE';
        """
        result = self.execute_one(query)
        return result['count'] if result else 0
    
    def get_tables(self) -> List[str]:
        """
        Get list of all tables in public schema
        
        Returns:
            List of table names
        """
        query = """
            SELECT table_name
            FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_type = 'BASE TABLE'
            ORDER BY table_name;
        """
        results = self.execute_many(query)
        return [row['table_name'] for row in results]
    
    def health_check(self) -> Dict[str, Any]:
        """
        Check database health
        
        Returns:
            Health status dict
        """
        try:
            result = self.execute_one("SELECT 1 as health_check;")
            table_count = self.get_table_count()
            
            return {
                'status': 'healthy',
                'connected': True,
                'tables': table_count,
                'pool_size': self.pool.maxconn if self.pool else 0
            }
        except Exception as e:
            database_logger.error(f"Health check failed: {e}")
            return {
                'status': 'unhealthy',
                'connected': False,
                'error': str(e)
            }
    
    def close(self):
        """Close all connections in pool"""
        if self.pool:
            self.pool.closeall()
            database_logger.info("Database connection pool closed")


# =============================================================================
# GLOBAL DATABASE INSTANCE
# =============================================================================
db = Database()


if __name__ == '__main__':
    # Test database connection and operations
    print("\n" + "=" * 60)
    print("TESTING DATABASE CONNECTION")
    print("=" * 60 + "\n")
    
    # Test 1: Health check
    print("1️⃣  Health Check:")
    health = db.health_check()
    print(f"   Status: {health['status']}")
    print(f"   Tables: {health['tables']}")
    print(f"   Pool Size: {health.get('pool_size', 'N/A')}")
    
    # Test 2: List tables
    print("\n2️⃣  Tables in database:")
    tables = db.get_tables()
    for table in tables:
        print(f"   - {table}")
    
    # Test 3: Query schema version
    print("\n3️⃣  Schema Version:")
    version = db.execute_one("SELECT * FROM schema_version ORDER BY version DESC LIMIT 1;")
    if version:
        print(f"   Version: {version['version']}")
        print(f"   Applied: {version['applied_at']}")
        print(f"   Description: {version['description']}")
    
    # Test 4: Count users
    print("\n4️⃣  User Count:")
    user_count = db.execute_one("SELECT COUNT(*) as count FROM users;")
    if user_count:
        print(f"   Total users: {user_count['count']}")
    else:
        print("   Total users: 0")
    
    print("\n" + "=" * 60)
    print("✅ All database tests passed!")
    print("=" * 60 + "\n")
