import 'package:web/web.dart' as web;

const bool canOpenConversation = true;

bool openConversation(Uri uri) {
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}
