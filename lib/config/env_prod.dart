class Env {
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL', 
    defaultValue: 'https://vackbpaebrwtgcadsqlc.supabase.co');
  static const String supabaseKey = String.fromEnvironment('SUPABASE_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhY2ticGFlYnJ3dGdjYWRzcWxjIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc0NzEwOTE0NCwiZXhwIjoyMDYyNjg1MTQ0fQ.lTYj77VAtim-tLN7IObQqLpu9GqKXACC0ye0-vA1_68');
}