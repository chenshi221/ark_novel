// 仿真翻页的演示页（只用来在浏览器里目测效果）：
//   flutter build web -t tool/curl_demo.dart
import 'package:flutter/material.dart';
import 'package:ark_novel/next/reader/page_curl.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Demo()));

class _Demo extends StatelessWidget {
  const _Demo();

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFFF6F1E7);
    final text = List.generate(40, (i) => '　　第${i + 1}行：这是用来观察翻页效果的一行正文，纸张沿折线翻过去，露出下一页。').join('\n');
    return Scaffold(
      backgroundColor: bg,
      body: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: PageCurl(
          debugT: double.tryParse(Uri.base.queryParameters['t'] ?? ''),
          debugDir: int.tryParse(Uri.base.queryParameters['dir'] ?? '') ?? 1,
          debugCorner: double.tryParse(Uri.base.queryParameters['corner'] ?? '') ?? 1,
          pageCount: 5,
          initialIndex: 0,
          background: bg,
          pageBuilder: (context, i, live) => Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('第 ${i + 1} 页', style: TextStyle(fontSize: 28, fontFamily: 'LXGWWenKai', color: Colors.primaries[i * 3 % 18])),
                const SizedBox(height: 12),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 17, height: 1.8, color: Color(0xFF2B2A27), fontFamily: 'LXGWWenKai'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
