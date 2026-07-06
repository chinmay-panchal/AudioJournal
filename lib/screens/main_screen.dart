import 'package:flutter/material.dart';
import 'tabs/record_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/calendar_tab.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _tabs = [
    const RecordTab(),
    const LibraryTab(),
    const CalendarTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.white,
      body: _tabs[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(
              color: Colors.grey.withValues(alpha: 0.2),
              width: 1.0,
            ),
          ),
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.white,
          elevation: 0,
          currentIndex: _currentIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          selectedItemColor: const Color(0xFFF97316),
          unselectedItemColor: Colors.grey.shade400,
          selectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.mic_none_outlined, size: 26),
              activeIcon: Icon(Icons.mic, size: 26),
              label: 'Record',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.menu_book_outlined, size: 26),
              activeIcon: Icon(Icons.menu_book, size: 26),
              label: 'Library',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_today_outlined, size: 24),
              activeIcon: Icon(Icons.calendar_today, size: 24),
              label: 'Calendar',
            ),
          ],
        ),
      ),
    );
  }
}
