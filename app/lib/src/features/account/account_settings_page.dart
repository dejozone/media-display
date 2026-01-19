import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AccountSettingsPage extends ConsumerWidget {
  const AccountSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E1117), Color(0xFF0D1021)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF111624).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 10)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Account', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text('Profile, avatar, and service preferences (coming soon).', style: TextStyle(color: Color(0xFF9FB1D0))),
                  SizedBox(height: 14),
                  _PlaceholderRow(label: 'Display Name'),
                  SizedBox(height: 10),
                  _PlaceholderRow(label: 'Email'),
                  SizedBox(height: 10),
                  _PlaceholderRow(label: 'Connected providers'),
                  SizedBox(height: 14),
                  Text('We will add editing and uploads here.', style: TextStyle(color: Color(0xFFC2CADC))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceholderRow extends StatelessWidget {
  const _PlaceholderRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: const Text('Edit', style: TextStyle(color: Color(0xFF9FB1D0), fontSize: 12)),
        ),
      ],
    );
  }
}
