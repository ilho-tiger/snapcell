import 'package:flutter/material.dart';

void main() => runApp(const SnapcellApp());

class SnapcellApp extends StatelessWidget {
  const SnapcellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Snapcell'))),
    );
  }
}
