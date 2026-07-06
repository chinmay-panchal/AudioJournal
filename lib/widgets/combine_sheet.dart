import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/api_service.dart';

// Public model for transcript list items
class TranscriptItem {
  final String id;
  final String title;

  const TranscriptItem({required this.id, required this.title});
}

class CombineSheet extends StatefulWidget {
  final List<TranscriptItem> items;
  final void Function(List<String> selectedIds) onGenerate;

  const CombineSheet({super.key, required this.items, required this.onGenerate});

  @override
  State<CombineSheet> createState() => _CombineSheetState();
}

class _CombineSheetState extends State<CombineSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {};
  }

  bool get _allSelected => _selected.length == widget.items.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.items.map((i) => i.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewInsets.bottom;
    const accent = Color(0xFFF97316);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.only(bottom: bottomPad),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6366F1), accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 17),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Combine & Summarize', style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w700)),
                      Text('Select recordings to combine into one summary', style: TextStyle(color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _toggleAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _allSelected ? accent.withValues(alpha: 0.1) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _allSelected ? accent : Colors.grey.shade300),
                    ),
                    child: Text(
                      _allSelected ? 'Deselect all' : 'Select all',
                      style: TextStyle(color: _allSelected ? accent : Colors.grey.shade600, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: Colors.grey.withValues(alpha: 0.1)),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.38),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: widget.items.length,
              itemBuilder: (ctx, i) {
                final item = widget.items[i];
                final checked = _selected.contains(item.id);
                return InkWell(
                  onTap: () => setState(() {
                    checked ? _selected.remove(item.id) : _selected.add(item.id);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: checked ? accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: checked ? accent : Colors.grey.shade400, width: 1.5),
                          ),
                          child: checked ? const Icon(Icons.check_rounded, color: Colors.white, size: 14) : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              color: Colors.black87,
                              fontSize: 13.5,
                              fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(height: 1, color: Colors.grey.withValues(alpha: 0.1)),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _selected.isEmpty ? Colors.grey.shade100 : accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _selected.isEmpty ? 'None selected' : '${_selected.length} selected',
                    style: TextStyle(color: _selected.isEmpty ? Colors.grey.shade500 : accent, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _selected.isEmpty ? 0.4 : 1.0,
                  child: GestureDetector(
                    onTap: _selected.isEmpty ? null : () => widget.onGenerate(_selected.toList()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF6366F1), accent],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: _selected.isEmpty ? [] : [
                          BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4)),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 15),
                          SizedBox(width: 7),
                          Text('Generate', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class LoadingDialog extends StatelessWidget {
  const LoadingDialog({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFF97316);
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: CircularProgressIndicator(color: accent, strokeWidth: 2.5),
              ),
            ),
            const SizedBox(height: 18),
            const Text('Generating summary…', style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Combining selected recordings with AI', style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class SummaryResultDialog extends StatelessWidget {
  final String title;
  final String summaryText;
  final VoidCallback onCopy;

  const SummaryResultDialog({super.key, required this.title, required this.summaryText, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFFF97316).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 12, color: Color(0xFFF97316)),
                      SizedBox(width: 5),
                      Text('Combined Summary', style: TextStyle(color: Color(0xFFF97316), fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Copy summary',
                  child: InkWell(
                    onTap: onCopy,
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.copy_rounded, size: 18, color: Colors.grey)),
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.close_rounded, size: 18, color: Colors.grey)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title, style: const TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w700, height: 1.3)),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Text(summaryText, style: const TextStyle(color: Colors.black87, fontSize: 14, height: 1.6)),
            ),
          ),
        ],
      ),
    );
  }
}
