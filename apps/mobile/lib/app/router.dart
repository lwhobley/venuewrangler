import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_providers.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/dashboard/placeholder_home_screen.dart';

/// Redirects between the auth flow and the authenticated app shell based on
/// [isSignedInProvider]. Feature routes are added here as Phase 2 builds them; this is
/// deliberately the only router in the app (see core/README conventions) so deep links and
/// push-notification routing (ported from the reference app's notification-to-tab mapping)
/// have one place to register.
final routerProvider = Provider<GoRouter>((ref) {
  final isSignedIn = ref.watch(isSignedInProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final goingToSignIn = state.matchedLocation == '/sign-in';
      if (!isSignedIn && !goingToSignIn) return '/sign-in';
      if (isSignedIn && goingToSignIn) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const PlaceholderHomeScreen(),
      ),
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
    ],
  );
});
