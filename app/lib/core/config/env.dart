/// Build-time environment configuration.
///
/// Override with `--dart-define=API_BASE_URL=https://...` at build/run time.
class Env {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );
}
