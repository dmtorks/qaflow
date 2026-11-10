import 'package:flutter/material.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _error = false;

  bool get _canSubmit => _username.text.isNotEmpty && _password.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _username.addListener(_refresh);
    _password.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  void _submit() {
    if (!_canSubmit) return;
    if (_password.text == 'secret') {
      Navigator.of(context).pushReplacementNamed('/list');
    } else {
      setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome'),
        // In the app bar so a short landscape screen cannot push it out of view.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              MediaQuery.orientationOf(context) == Orientation.landscape ? 'Landscape layout' : 'Portrait layout',
              key: const ValueKey('layout'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  identifier: 'username',
                  child: TextField(
                    key: const ValueKey('username'),
                    controller: _username,
                    decoration: const InputDecoration(labelText: 'Username'),
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  identifier: 'password',
                  child: TextField(
                    key: const ValueKey('password'),
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(height: 16),
                if (_error)
                  Text(
                    'Wrong password',
                    key: const ValueKey('login_error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                const SizedBox(height: 16),
                Semantics(
                  identifier: 'login',
                  child: ElevatedButton(
                    key: const ValueKey('login'),
                    onPressed: _canSubmit ? _submit : null,
                    child: const Text('Sign in'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
