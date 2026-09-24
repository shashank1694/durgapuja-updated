import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/database_service.dart';
import '../../utils/colors.dart';

class AiLogsScreen extends StatefulWidget {
  const AiLogsScreen({super.key});

  @override
  State<AiLogsScreen> createState() => _AiLogsScreenState();
}

class _AiLogsScreenState extends State<AiLogsScreen> {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _loading = true);
    final list = await DatabaseService.getAllAiLogs();
    if (mounted) {
      setState(() {
        _logs = list;
        _loading = false;
      });
    }
  }

  Future<void> _deleteLog(int id) async {
    try {
      await DatabaseService.deleteAiLog(id);
      await _loadLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Log deleted'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _formatTimestamp(String? ts) {
    if (ts == null || ts.isEmpty) return '—';
    try {
      final dt = DateTime.parse(ts);
      return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts;
    }
  }

  String _formatAmount(dynamic amount) {
    if (amount == null) return '—';
    if (amount is num) return '₹ ${amount.toStringAsFixed(0)}';
    return '₹ ${amount.toString()}';
  }

  String _prettyJson(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return '{}';
    try {
      final decoded = jsonDecode(jsonStr);
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(decoded);
    } catch (_) {
      return jsonStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) context.go('/finance/reports');
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundCream,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/finance/reports'),
          ),
          title: const Text('AI Transactions'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _loadLogs,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _logs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.history,
                            size: 64,
                            color: AppColors.textLight,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No AI transactions yet',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.textLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return _AiLogCard(
                        log: _logs[index],
                        formatTimestamp: _formatTimestamp,
                        formatAmount: _formatAmount,
                        prettyJson: _prettyJson,
                        onDelete: _deleteLog,
                      );
                    },
                  ),
      ),
    );
  }
}

class _AiLogCard extends StatefulWidget {
  final Map<String, dynamic> log;
  final String Function(String?) formatTimestamp;
  final String Function(dynamic) formatAmount;
  final String Function(String?) prettyJson;
  final Future<void> Function(int id) onDelete;

  const _AiLogCard({
    required this.log,
    required this.formatTimestamp,
    required this.formatAmount,
    required this.prettyJson,
    required this.onDelete,
  });

  @override
  State<_AiLogCard> createState() => _AiLogCardState();
}

class _AiLogCardState extends State<_AiLogCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final id = widget.log['id'] as int?;
    final timestamp = widget.log['timestamp'] as String?;
    final bengaliText = widget.log['bengali_text'] as String? ?? '';
    final englishText = widget.log['english_text'] as String? ?? '';
    final gptJsonStr = widget.log['gpt_json'] as String?;
    final intent = widget.log['intent'] as String? ?? '—';
    final amount = widget.log['amount'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() => _expanded = !_expanded);
            },
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.formatTimestamp(timestamp),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textLight,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (id != null)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          color: Colors.red.shade400,
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete log'),
                                content: const Text(
                                  'Remove this AI transaction log?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(ctx).pop(true),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.red,
                                    ),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) await widget.onDelete(id);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bengaliText,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    englishText,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textLight,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Chip(
                        label: Text(
                          intent,
                          style: const TextStyle(fontSize: 12),
                        ),
                        backgroundColor: AppColors.cardCream,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      Text(
                        widget.formatAmount(amount),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: AppColors.textLight,
                      ),
                      Text(
                        _expanded ? 'Hide JSON' : 'Show full JSON',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textLight,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                widget.prettyJson(gptJsonStr),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Colors.grey.shade800,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
