import 'package:vaster_ast/vaster_ast.dart';

/// Specialized Flutter design system component generating theme tokens, color palettes,
/// and typography definitions.
class FlutterDesignSystemComponent extends ComposableNode {
  final String primaryColorHex;
  final String accentColorHex;

  const FlutterDesignSystemComponent({
    this.primaryColorHex = '#6750A4',
    this.accentColorHex = '#625B71',
  });

  @override
  VasterNode build(BuildContext context) {
    final primary = primaryColorHex.replaceFirst('#', '0xFF');
    final accent = accentColorHex.replaceFirst('#', '0xFF');
    final colorsContent = '''
import 'package:flutter/material.dart';

abstract final class AppColors {
  static const Color primary = Color($primary);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color secondary = Color($accent);
  static const Color background = Color(0xFFFEF7FF);
  static const Color surface = Color(0xFFF7F2FA);
  static const Color cardBorder = Color(0xFFE7E0EC);
  static const Color textPrimary = Color(0xFF1D1B20);
  static const Color textSecondary = Color(0xFF49454F);
}
''';

    final themeContent = '''
import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.background,
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: AppColors.cardBorder),
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
    );
  }
}
''';

    return Transaction(children: [
      WriteFile(
        path: Template.text('/workspace/lib/core/theme/app_colors.dart'),
        content: Template.text(colorsContent),
      ),
      WriteFile(
        path: Template.text('/workspace/lib/core/theme/app_theme.dart'),
        content: Template.text(themeContent),
      ),
    ]);
  }
}

/// Specialized Flutter domain data model node emitting clean entity classes, DTOs,
/// copyWith helpers, and JSON serialization methods.
class FlutterDomainModelNode extends ComposableNode {
  final String featureName;
  final String entityName;
  final Map<String, String> fields;

  const FlutterDomainModelNode({
    required this.featureName,
    required this.entityName,
    required this.fields,
  });

  @override
  VasterNode build(BuildContext context) {
    final buffer = StringBuffer();
    buffer.writeln("import 'package:flutter/foundation.dart';");
    buffer.writeln();
    buffer.writeln('@immutable');
    buffer.writeln('class $entityName {');

    // Field declarations
    for (final entry in fields.entries) {
      buffer.writeln('  final ${entry.value} ${entry.key};');
    }
    buffer.writeln();

    // Constructor
    buffer.writeln('  const $entityName({');
    for (final entry in fields.entries) {
      buffer.writeln('    required this.${entry.key},');
    }
    buffer.writeln('  });');
    buffer.writeln();

    // copyWith
    buffer.writeln('  $entityName copyWith({');
    for (final entry in fields.entries) {
      buffer.writeln('    ${entry.value}? ${entry.key},');
    }
    buffer.writeln('  }) {');
    buffer.writeln('    return $entityName(');
    for (final entry in fields.entries) {
      buffer.writeln('      ${entry.key}: ${entry.key} ?? this.${entry.key},');
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // toJson
    buffer.writeln('  Map<String, dynamic> toJson() => {');
    for (final entry in fields.entries) {
      buffer.writeln("        '${entry.key}': ${entry.key},");
    }
    buffer.writeln('      };');
    buffer.writeln();

    // fromJson
    buffer.writeln('  factory $entityName.fromJson(Map<String, dynamic> json) {');
    buffer.writeln('    return $entityName(');
    for (final entry in fields.entries) {
      final type = entry.value;
      final key = entry.key;
      final defaultVal = type == 'int'
          ? '0'
          : type == 'bool'
              ? 'false'
              : "''";
      buffer.writeln("      $key: json['$key'] as $type? ?? $defaultVal,");
    }
    buffer.writeln('    );');
    buffer.writeln('  }');

    buffer.writeln('}');

    return Transaction(children: [
      WriteFile(
        path: Template.text('/workspace/lib/features/$featureName/domain/${entityName.toLowerCase()}.dart'),
        content: Template.text(buffer.toString()),
      ),
    ]);
  }
}

String _toPascalCase(String input) {
  if (input.isEmpty) return input;
  return input
      .split(RegExp(r'[_\-\s]+'))
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1))
      .join();
}

/// Specialized Flutter BLoC state management component generating events, states,
/// and Bloc business logic controllers.
class FlutterBlocStateManagementComponent extends ComposableNode {
  final String featureName;
  final String blocName;
  final String entityName;

  const FlutterBlocStateManagementComponent({
    required this.featureName,
    required this.blocName,
    required this.entityName,
  });

  @override
  VasterNode build(BuildContext context) {
    final pascalFeature = _toPascalCase(featureName);
    final entityLower = entityName.toLowerCase();

    final stateContent = '''
import '../../domain/$entityLower.dart';

sealed class ${blocName}State {
  const ${blocName}State();
}

final class ${blocName}Initial extends ${blocName}State {
  const ${blocName}Initial();
}

final class ${blocName}Loading extends ${blocName}State {
  const ${blocName}Loading();
}

final class ${blocName}Loaded extends ${blocName}State {
  final List<$entityName> items;
  const ${blocName}Loaded(this.items);
}

final class ${blocName}Error extends ${blocName}State {
  final String message;
  const ${blocName}Error(this.message);
}
''';

    final eventContent = '''
import '../../domain/$entityLower.dart';

sealed class ${blocName}Event {
  const ${blocName}Event();
}

final class Load${pascalFeature}ItemsEvent extends ${blocName}Event {
  const Load${pascalFeature}ItemsEvent();
}

final class Add${entityName}Event extends ${blocName}Event {
  final $entityName item;
  const Add${entityName}Event(this.item);
}
''';

    final blocContent = '''
import 'package:flutter_bloc/flutter_bloc.dart';
import '${featureName}_event.dart';
import '${featureName}_state.dart';
import '../../domain/$entityLower.dart';

class ${blocName}Bloc extends Bloc<${blocName}Event, ${blocName}State> {
  final List<$entityName> _items = [];

  ${blocName}Bloc() : super(const ${blocName}Initial()) {
    on<Load${pascalFeature}ItemsEvent>(_onLoadItems);
    on<Add${entityName}Event>(_onAddItem);
  }

  Future<void> _onLoadItems(
    Load${pascalFeature}ItemsEvent event,
    Emitter<${blocName}State> emit,
  ) async {
    emit(const ${blocName}Loading());
    await Future.delayed(const Duration(milliseconds: 100));
    emit(${blocName}Loaded(List.unmodifiable(_items)));
  }

  void _onAddItem(
    Add${entityName}Event event,
    Emitter<${blocName}State> emit,
  ) {
    _items.add(event.item);
    emit(${blocName}Loaded(List.unmodifiable(_items)));
  }
}
''';

    return Transaction(children: [
      WriteFile(
        path: Template.text('/workspace/lib/features/$featureName/presentation/bloc/${featureName}_state.dart'),
        content: Template.text(stateContent),
      ),
      WriteFile(
        path: Template.text('/workspace/lib/features/$featureName/presentation/bloc/${featureName}_event.dart'),
        content: Template.text(eventContent),
      ),
      WriteFile(
        path: Template.text('/workspace/lib/features/$featureName/presentation/bloc/${featureName}_bloc.dart'),
        content: Template.text(blocContent),
      ),
    ]);
  }
}

/// Specialized Flutter feature widget component emitting reactive UI pages, cards,
/// micro-animations, and BlocBuilder integration.
class FlutterFeatureWidgetComponent extends ComposableNode {
  final String featureName;
  final String pageTitle;
  final String blocName;
  final String entityName;

  const FlutterFeatureWidgetComponent({
    required this.featureName,
    required this.pageTitle,
    required this.blocName,
    required this.entityName,
  });

  @override
  VasterNode build(BuildContext context) {
    final pascalFeature = _toPascalCase(featureName);

    final pageContent = '''
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/${featureName}_bloc.dart';
import '../bloc/${featureName}_event.dart';
import '../bloc/${featureName}_state.dart';
import '../../../../core/theme/app_colors.dart';

class ${pascalFeature}Page extends StatelessWidget {
  const ${pascalFeature}Page({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => ${blocName}Bloc()..add(const Load${pascalFeature}ItemsEvent()),
      child: Scaffold(
        appBar: AppBar(
          title: Text('$pageTitle'),
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
        ),
        body: BlocBuilder<${blocName}Bloc, ${blocName}State>(
          builder: (context, state) {
            return switch (state) {
              ${blocName}Initial() || ${blocName}Loading() => const Center(
                  child: CircularProgressIndicator(),
                ),
              ${blocName}Loaded(:final items) => items.isEmpty
                  ? const Center(
                      child: Text('No items available yet.', key: Key('empty_state_text')),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            key: Key('item_\$index'),
                            title: Text('Item #\${index + 1}'),
                            subtitle: Text('ID: \${item.id}'),
                          ),
                        );
                      },
                    ),
              ${blocName}Error(:final message) => Center(
                  child: Text('Error: \$message'),
                ),
            };
          },
        ),
      ),
    );
  }
}
''';

    return Transaction(children: [
      WriteFile(
        path: Template.text('/workspace/lib/features/$featureName/presentation/pages/${featureName}_page.dart'),
        content: Template.text(pageContent),
      ),
    ]);
  }
}

/// Specialized Flutter widget test component emitting flutter_test assertions.
class FlutterWidgetTestComponent extends ComposableNode {
  final String featureName;
  final String pageTitle;

  const FlutterWidgetTestComponent({
    required this.featureName,
    required this.pageTitle,
  });

  @override
  VasterNode build(BuildContext context) {
    final pascalFeature = _toPascalCase(featureName);

    final testContent = '''
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_app/features/$featureName/presentation/pages/${featureName}_page.dart';

void main() {
  testWidgets('$pascalFeature Page renders title and empty state text', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ${pascalFeature}Page(),
      ),
    );

    // Initial pump shows progress indicator
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Settle async timers to complete BLoC loading state
    await tester.pumpAndSettle();

    expect(find.text('$pageTitle'), findsOneWidget);
    expect(find.byKey(const Key('empty_state_text')), findsOneWidget);
  });
}
''';

    return Transaction(children: [
      WriteFile(
        path: Template.text('/workspace/test/features/$featureName/${featureName}_page_test.dart'),
        content: Template.text(testContent),
      ),
    ]);
  }
}
