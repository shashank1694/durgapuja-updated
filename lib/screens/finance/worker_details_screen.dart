import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/database_service.dart';
import '../../widgets/language_toggle_action.dart';

class WorkerDetailsScreen extends StatefulWidget {
  final String workerName;
  final String category;
  final String budget;
  final String paid;
  final bool isNewWorker;

  const WorkerDetailsScreen({
    super.key,
    required this.workerName,
    required this.category,
    required this.budget,
    required this.paid,
    this.isNewWorker = false,
  });

  // Constructor for navigation with arguments
  WorkerDetailsScreen.fromArgs(Map<String, dynamic> args)
      : this(
          workerName: args['name'] ?? 'Unknown',
          category: args['category'] ?? 'Unknown',
          budget: args['budget'] ?? '0',
          paid: args['paid'] ?? '0',
          isNewWorker: args['isNewWorker'] == true,
        );

  @override
  State<WorkerDetailsScreen> createState() => _WorkerDetailsScreenState();
}

class _WorkerDetailsScreenState extends State<WorkerDetailsScreen> {
  late TextEditingController _workerNameController;
  late TextEditingController _budgetController;
  late TextEditingController _paidController;
  final TextEditingController _amountPaidController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _workerNameController = TextEditingController(text: widget.workerName);
    _budgetController = TextEditingController(text: widget.budget);
    _paidController = TextEditingController(text: widget.paid);
  }

  @override
  void dispose() {
    _workerNameController.dispose();
    _budgetController.dispose();
    _paidController.dispose();
    _amountPaidController.dispose();
    super.dispose();
  }

  double get _parsedBudget =>
      double.tryParse(_budgetController.text.replaceAll(',', '')) ?? 0.0;
  double get _parsedPaid =>
      double.tryParse(_paidController.text.replaceAll(',', '')) ?? 0.0;
  double get _pending => (_parsedBudget - _parsedPaid).clamp(0.0, double.infinity);

  Future<void> _confirmDetails() async {
    final workerName = _workerNameController.text.trim();
    if (workerName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter worker name')),
      );
      return;
    }

    final amountPaid = double.tryParse(_amountPaidController.text) ?? 0.0;
    if (amountPaid <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount')),
      );
      return;
    }

    if (widget.isNewWorker) {
      final budget = _parsedBudget;
      if (budget <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a valid budget')),
        );
        return;
      }
    }

    // Parse category to extract idol_type and worker_type
    final parts = widget.category.split(' / ');
    final idolType = parts.isNotEmpty ? parts[0] : 'Unknown';
    final workerType = parts.length > 1 ? parts[1] : 'Unknown';

    final amountTotal = widget.isNewWorker ? _parsedBudget : (double.tryParse(widget.budget.replaceAll(',', '')) ?? 0.0);

    // Insert worker fund with transaction log
    await DatabaseService.insertWorkerFundManual(
      idolType: idolType,
      workerType: workerType,
      workerName: workerName,
      amountPaid: amountPaid,
      amountTotal: amountTotal,
    );

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Worker payment added successfully')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.isNewWorker ? _pending : (double.tryParse(widget.budget.replaceAll(',', '')) ?? 0) - (double.tryParse(widget.paid.replaceAll(',', '')) ?? 0);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) context.go('/finance/dashboard');
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5E6D3),
        appBar: AppBar(
          title: Text(widget.isNewWorker
              ? (_workerNameController.text.isEmpty ? 'New Worker' : _workerNameController.text)
              : widget.workerName),
          backgroundColor: const Color(0xFF9A5222),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/finance/dashboard'),
          ),
          actions: const [
            LanguageToggleAction(),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {},
          backgroundColor: const Color(0xFF9A5222),
          child: const Icon(Icons.mic, color: Colors.white),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            child: Form(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Worker Name (required)
                  const Text("Worker Name", style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _workerNameController,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Enter worker name',
                      filled: true,
                      fillColor: const Color(0xFFEEDFD0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Text(
                    "Category: ${widget.category}",
                    style: const TextStyle(fontSize: 14, color: Colors.black54),
                  ),

                  const SizedBox(height: 20),

                  // Budget + Paid Row
                  Row(
                    children: [
                      // Budget Box
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: const Color(0xFF9A5222),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Budget", style: TextStyle(color: Colors.white)),
                              const SizedBox(height: 6),
                              widget.isNewWorker
                                  ? TextFormField(
                                      controller: _budgetController,
                                      keyboardType: TextInputType.number,
                                      style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w600),
                                      decoration: InputDecoration(
                                        hintText: '0',
                                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.8)),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      cursorColor: Colors.white,
                                      onChanged: (_) => setState(() {}),
                                    )
                                  : Text("₹ ${widget.budget}", style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Paid Box
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Paid", style: TextStyle(color: Colors.black)),
                              const SizedBox(height: 6),
                              widget.isNewWorker
                                  ? TextFormField(
                                      controller: _paidController,
                                      keyboardType: TextInputType.number,
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                                      decoration: const InputDecoration(
                                        hintText: '0',
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    )
                                  : Text("₹ ${widget.paid}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // Pending Amount
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEDFD0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Pending amount"),
                        const SizedBox(height: 6),
                        Text(
                          "₹ ${pending.toStringAsFixed(0)}",
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 25),

                  // Amount Paid Input
                  const Text("Amount paid", style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEDFD0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const Text("₹ ", style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextFormField(
                            controller: _amountPaidController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              hintText: "0.00",
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Confirm Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _confirmDetails,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9A5222),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                      ),
                      child: const Text("Confirm Details", style: TextStyle(fontSize: 16, color: Colors.white)),
                    ),
                  ),

                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}