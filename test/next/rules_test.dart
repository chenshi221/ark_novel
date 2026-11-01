import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/rules.dart';

void main() {
  test('按顺序套用规则，支持分组引用', () {
    final rules = [
      const ReplaceRule(pattern: r'(\d+)话', replacement: r'第$1话'),
      const ReplaceRule(pattern: '广告', replacement: ''),
    ];
    expect(ReplaceRules.apply('12话 广告正文', rules), '第12话 正文');
  });

  test('停用的和写错的规则被跳过', () {
    final rules = [const ReplaceRule(pattern: 'a', replacement: 'b', enabled: false), const ReplaceRule(pattern: '(', replacement: 'x')];
    expect(ReplaceRules.apply('aaa(', rules), 'aaa(');
    expect(ReplaceRule.validate('('), isNotNull);
    expect(ReplaceRule.validate('a+'), isNull);
  });

  test('高亮规则：先写的优先，重叠的让位，结果按位置排序', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.highlight, id: 'a'),
      const ReplaceRule(pattern: '云海|林', replacement: '', kind: RuleKind.highlight, id: 'b'),
      const ReplaceRule(pattern: '广告', replacement: '', id: 'c'),
    ];
    final marks = ReplaceRules.marks('林云看见云海，广告', rules);
    expect([for (final m in marks) (m.start, m.end, m.rule.id)], [(0, 2, 'a'), (4, 6, 'b')]);
  });

  test('高亮规则不参与文字替换', () {
    final rules = [const ReplaceRule(pattern: '林云', replacement: 'X', kind: RuleKind.highlight, id: 'a')];
    expect(ReplaceRules.apply('林云', rules), '林云');
  });

  test('变色规则参与着色但不是高亮；单本书的规则只在那本书生效', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.color, id: 'a'),
      const ReplaceRule(pattern: '云海', replacement: '', kind: RuleKind.highlight, id: 'b', aid: '1'),
    ];
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '1')) (m.rule.id, m.rule.kind)], [('a', RuleKind.color), ('b', RuleKind.highlight)]);
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '2')) m.rule.id], ['a']);
    expect(ReplaceRules.apply('林云', rules), '林云');
  });
}
