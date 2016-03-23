part of eventsourcing;

/// Status einer WebSocket-Verbindung
enum WebSocketState { UNAUTHENTICATED, OK, CLOSED }

/**
 * Kapselt eine WebSocket-Verbindung. Über die Verbindung können
 * Kommandos und Anfragen an den Server gestellt werden.
 *
 * ## Legacy-Protokoll (JSON)
 * Nach dem Format `{"action": "...", "track": xxx}`
 * Nach Verbindungsaufbau zum Server ist eine Verbindung zunächst nicht authentifiziert.
 * Das erste Paket vom Client muss ein "username"- und "password"-Feld enthalten,
 * woraufhin der Server die Logindaten mit einem [Authenticator] prüft. Daraufhin
 * wird die Verbindung als aufgebaut betrachtet bzw. terminiert.
 * Anschließend können Anfragen (`{"action": "get", "track": xxx}`) und Kommandos (`{"action": "push", "track": xxx}`)
 * gestellt werden, wobei eine `track`-Nummer mitgesendet werden muss. Diese schickt
 * der Server bei der Antwort mit, daher können mehrere Anfragen asynchron gestellt werden.
 * Im Fehlerfall antwortet der Server immer mit (`{"error": "...", "track": xxx}`).
 * Mit der Aktion (`{"action": "subscribe", "track": xxx}`) wird eine neue
 * [Subscription] erstellt.
 */
class WebSocketConnection {
  /// Zugehöriger Raw-Socket
  /// TODO: Kapseln
  final WebSocket ws;

  /// Zugehöriges eventsourcing-System. Eine [WebSocketConnection] gehört immer zu genau einem System.
  final EventRouter router;

  /// Verbindungszustand (siehe Protokollbeschreibung)
  WebSocketState state = WebSocketState.UNAUTHENTICATED;

  /// Information über den verbindenen Client (Netzwerkadresse etc)
  final HttpConnectionInfo info;

  /// UserID des Benutzers. Erst gültig nach Authentifizierung.
  int user = 0;

  /// Benutzername des Benutzers. Erst gültig nach Authentifizierung.
  String username = "";

  /// Offene Abos. Zuordnung erfolgt über die jeweils mitgeschickte `trackId`.
  final Map<int, Subscription> subscriptions = {};

  /// Bearbeitet die erste Anfrage, die die Anmeldedaten enthalten muss. Im Fehlerfall
  /// wird die Verbindung sofort abgebrochen (WS-Fehlercode 4401) und der Future
  /// mit einem Fehler beendet.
  Future onAuthRequest(final Map data) async {
    final String nusername = data["username"];
    final String password = data["password"];

    try {
      user = await router.authenticator(
          nusername, password, info.remoteAddress.address, router.db);
    } catch (e) {
      ws.close(4401);
      print(
          "WebSocket-Login als $nusername an ${info.remoteAddress.host} abgelehnt");
      rethrow;
    }

    state = WebSocketState.OK;
    username = nusername;
    print("$username an ${info.remoteAddress.host} angemeldet");
  }

  /// Wird nach Empfang eines vollständigen [WebSocket]-Pakets aufgerufen.
  /// Fehler werden abgefangen, der zurückgegebene Future hat immer Erfolg.
  Future onData(final String rawData) async {
    try {
      final Map data = JSON.decode(rawData);

      int trackId = -1;
      if (data.containsKey("track")) {
        trackId = data["track"];
        data.remove("track");
      }

      if (state == WebSocketState.UNAUTHENTICATED) await onAuthRequest(data);

      // print(data);

      final String type = data["type"];
      data.remove("type");

      switch (type) {
        case "get":
          try {
            final Map res = await router.submitQuery(new Map.from(data), user);
            res["track"] = trackId;
            ws.add(JSON.encode(res));
          } catch (e) {
            print("WS-Queryfehler bei $username, Aktion ${data["action"]}: $e");
            // print(stacktrace);
            final Map res = {"error": e, "track": trackId};
            ws.add(JSON.encode(res));
          }
          break;

        case "push":
          try {
            if (data.containsKey("username")) data.remove("username");
            if (data.containsKey("password")) data.remove("password");

            final Map res = await router.submitEvent(
                new Map.from(data), {"websocket": this}, user);
            res["track"] = trackId;
            ws.add(JSON.encode(res));
          } catch (e, stacktrace) {
            print("WS-Eventfehler bei $username, Aktion ${data["action"]}: $e");
            print(stacktrace);
            final Map res = {"error": e, "track": trackId};
            ws.add(JSON.encode(res));
          }
          break;

        case "subscribe":
          subscriptions[trackId] =
              new Subscription(this, new Map.from(data), trackId);
          break;

        case "unsubscribe":
          final int unsubtrack = data["unsubtrack"];
          if (subscriptions.containsKey(unsubtrack))
            subscriptions[unsubtrack].remove();
          break;
      }
    } catch (e) {
      // TODO: Mehr Handling
      print("WS-Fehler: $e.");
    }
  }

  /// Entfernt die Verbindung aus dem Router und aktualisiert den Zustand. Der
  /// eigentliche [WebSocket] wird nicht geschlossen.
  void onClose() {
    state = WebSocketState.CLOSED;
    router.connections.remove(this);
    print("WS-Verbindung zu ${info.remoteAddress.host} verloren!");
  }

  /// Initialisiert eine neue WebSocket-Verbindung mit einem bereits geöffneten
  /// WebSocket.
  WebSocketConnection(this.ws, this.router, this.info) {
    ws.listen((dat) {
      onData(dat);
    }, onDone: onClose);
    router.connections.add(this);
    print("Neue WS-Verbindung zu ${info.remoteAddress.host}!");

    // Verbindung timeouten, wenn kein Login für 5 Minuten
    new Timer(new Duration(minutes: 5), () {
      if (state == WebSocketState.UNAUTHENTICATED) {
        print(
            "WebSocket-Timeout zu ${info.remoteAddress.host} (Keine Authentifizierung in 5 Minuten)");
        ws.close();
      }
    });
  }
}
