// Add your modules' endpoints to the `endpoints` directory. Run
// `serverpod generate` to produce the modules server and client code. Refer to
// the documentation on how to add endpoints to your server.

import 'dart:convert';
import 'dart:io'
;
import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';

import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:googleapis_auth/src/oauth2_flows/auth_code.dart';
import 'package:googleapis_auth/src/auth_http_utils.dart';
import 'package:googleapis/people/v1.dart';
import 'package:serverpod_auth_server/src/business/config.dart';
import 'package:serverpod_auth_server/src/business/user_images.dart';

import '../business/users.dart';
import '../generated/protocol.dart';

const _configFilePath = 'config/google_client_secret.json';

/// Endpoint for handling Sign in with Google.
class GoogleEndpoint extends Endpoint {
  final _GoogleClientSecret _googleClientSecret = _GoogleClientSecret(_configFilePath);

  /// Authenticates a user with Google.
  Future<AuthenticationResponse> authenticate(Session session, String authenticationCode) async {
    if (_googleClientSecret.json == null) {
      session.log('Sign in with Google is not initialized', level: LogLevel.warning);
      return AuthenticationResponse(success: false);
    }

    var authClient = await _GoogleUtils.clientViaClientSecretAndCode(
      _googleClientSecret.json!,
      authenticationCode, [
        'https://www.googleapis.com/auth/userinfo.profile',
        'profile',
        'email',
      ],
    );

    var api = PeopleServiceApi(authClient);
    var person = await api.people.get('people/me', personFields: 'emailAddresses,names,photos');

    if (person.names == null)
      return AuthenticationResponse(success: false);

    var fullName = person.names?[0].displayName; // TODO: Double check
    var name = person.names?[0].givenName;
    var image = person.photos?[0].url;
    var email = person.emailAddresses?[0].value;

    if (fullName == null || name == null || image == null || email == null)
      return AuthenticationResponse(success: false);

    email = email.toLowerCase();

    var userInfo = await Users.findUserByEmail(session, email);
    if (userInfo == null) {
      userInfo = UserInfo(
        userIdentifier: email,
        userName: name,
        fullName: fullName,
        email: email,
        active: true,
        blocked: false,
        created: DateTime.now().toUtc(),
        scopeNames: [],
      );
      userInfo = await Users.createUser(session, userInfo);

      // Set the user image.
      if (userInfo?.id != null && (person.photos?.isNotEmpty ?? false)) {
        var photo = person.photos![0];
        var url = photo.url;
        if (url != null && url.endsWith('s100')) {
          url = url.substring(0, url.length - 4) + 's${AuthConfig.current.userImageSize}';
        }

        if (url != null)
          await UserImages.setUserImageFromUrl(session, userInfo!.id!, Uri.parse(url));
      }
    }

    if (userInfo == null)
      return AuthenticationResponse(success: false);

    var authKey = await session.auth.signInUser(userInfo.id!, 'google');

    return AuthenticationResponse(
      success: true,
      keyId: authKey.id,
      key: authKey.key,
      userInfo: userInfo,
    );
  }
}

class _GoogleUtils {
  static Future<AutoRefreshingAuthClient> clientViaClientSecretAndCode(Map data,
      String authenticationCode, List<String> scopes) async {
    Map web = data['web'];
    String identifier = web['client_id'];
    String secret = web['client_secret'];
    List redirectURIs = web['redirect_uris'];
    String redirectURI = redirectURIs[0];
    var clientId = ClientId(identifier, secret);
    var client = http.Client();
    var credentials = await obtainAccessCredentialsUsingCode(
        clientId, authenticationCode, redirectURI, client);

    return AutoRefreshingClient(client, clientId, credentials,
        closeUnderlyingClient: true);
  }
}

class _GoogleClientSecret {
  String path;
  Map? json;

  _GoogleClientSecret(this.path) {
    try {
      var file = File(path);
      var jsonData = file.readAsStringSync();
      json = jsonDecode(jsonData);
    }
    catch(e) {
      print('serverpod_auth_server: Failed to load $_configFilePath. Sign in with  Google will be disabled.');
    }
  }
}