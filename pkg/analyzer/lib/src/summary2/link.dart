// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/context/context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/name_union.dart';
import 'package:analyzer/src/summary2/bundle_writer.dart';
import 'package:analyzer/src/summary2/detach_nodes.dart';
import 'package:analyzer/src/summary2/library_builder.dart';
import 'package:analyzer/src/summary2/linked_element_factory.dart';
import 'package:analyzer/src/summary2/macro_application.dart';
import 'package:analyzer/src/summary2/macro_declarations.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/summary2/simply_bounded.dart';
import 'package:analyzer/src/summary2/super_constructor_resolver.dart';
import 'package:analyzer/src/summary2/top_level_inference.dart';
import 'package:analyzer/src/summary2/type_alias.dart';
import 'package:analyzer/src/summary2/types_builder.dart';
import 'package:analyzer/src/summary2/variance_builder.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:analyzer/src/utilities/uri_cache.dart';
import 'package:macros/src/executor/multi_executor.dart' as macro;

Future<LinkResult> link({
  required LinkedElementFactory elementFactory,
  required OperationPerformanceImpl performance,
  required List<LibraryFileKind> inputLibraries,
  macro.MultiMacroExecutor? macroExecutor,
}) async {
  final linker = Linker(elementFactory, macroExecutor);
  await linker.link(
    performance: performance,
    inputLibraries: inputLibraries,
  );
  return LinkResult(
    resolutionBytes: linker.resolutionBytes,
  );
}

class Linker {
  final LinkedElementFactory elementFactory;
  final macro.MultiMacroExecutor? macroExecutor;
  late final DeclarationBuilder macroDeclarationBuilder;

  /// Libraries that are being linked.
  final Map<Uri, LibraryBuilder> builders = {};

  final Map<ElementImpl, ast.AstNode> elementNodes = Map.identity();

  late InheritanceManager3 inheritance; // TODO(scheglov): cache it

  late Uint8List resolutionBytes;

  LibraryMacroApplier? _macroApplier;

  Linker(this.elementFactory, this.macroExecutor) {
    macroDeclarationBuilder = DeclarationBuilder(
      nodeOfElement: (element) => elementNodes[element],
    );
  }

  AnalysisContextImpl get analysisContext {
    return elementFactory.analysisContext;
  }

  DeclaredVariables get declaredVariables {
    return analysisContext.declaredVariables;
  }

  LibraryMacroApplier? get macroApplier => _macroApplier;

  Reference get rootReference => elementFactory.rootReference;

  bool get _isLinkingDartCore {
    var dartCoreUri = uriCache.parse('dart:core');
    return builders.containsKey(dartCoreUri);
  }

  /// If the [element] is part of a library being linked, return the node
  /// from which it was created.
  ast.AstNode? getLinkingNode(Element element) {
    return elementNodes[element];
  }

  Future<void> link({
    required OperationPerformanceImpl performance,
    required List<LibraryFileKind> inputLibraries,
  }) async {
    for (var inputLibrary in inputLibraries) {
      LibraryBuilder.build(this, inputLibrary);
    }

    await _buildOutlines(
      performance: performance,
    );

    _writeLibraries();
  }

  void _buildClassSyntheticConstructors() {
    for (final library in builders.values) {
      library.buildClassSyntheticConstructors();
    }
  }

  void _buildElementNameUnions() {
    for (final builder in builders.values) {
      final element = builder.element;
      element.nameUnion = ElementNameUnion.forLibrary(element);
    }
  }

  void _buildEnumChildren() {
    for (var library in builders.values) {
      library.buildEnumChildren();
    }
  }

  void _buildExportScopes() {
    for (var library in builders.values) {
      library.buildInitialExportScope();
    }

    var exportingBuilders = <LibraryBuilder>{};
    var exportedBuilders = <LibraryBuilder>{};

    for (var library in builders.values) {
      library.addExporters();
    }

    for (var library in builders.values) {
      if (library.exports.isNotEmpty) {
        exportedBuilders.add(library);
        for (var export in library.exports) {
          exportingBuilders.add(export.exporter);
        }
      }
    }

    var both = <LibraryBuilder>{};
    for (var exported in exportedBuilders) {
      if (exportingBuilders.contains(exported)) {
        both.add(exported);
      }
      for (var export in exported.exports) {
        exported.exportScope.forEach(export.addToExportScope);
      }
    }

    while (true) {
      var hasChanges = false;
      for (var exported in both) {
        for (var export in exported.exports) {
          exported.exportScope.forEach((name, reference) {
            if (export.addToExportScope(name, reference)) {
              hasChanges = true;
            }
          });
        }
      }
      if (!hasChanges) break;
    }

    for (var library in builders.values) {
      library.storeExportScope();
    }
  }

  Future<LibraryMacroApplier?> _buildMacroApplier() async {
    final macroExecutor = this.macroExecutor;
    if (macroExecutor == null) {
      return null;
    }

    final macroApplier = LibraryMacroApplier(
      elementFactory: elementFactory,
      macroExecutor: macroExecutor,
      isLibraryBeingLinked: (uri) => builders.containsKey(uri),
      declarationBuilder: macroDeclarationBuilder,
      runDeclarationsPhase: _executeMacroDeclarationsPhase,
    );

    for (final library in builders.values) {
      await library.fillMacroApplier(macroApplier);
    }

    return _macroApplier = macroApplier;
  }

  Future<void> _buildOutlines({
    required OperationPerformanceImpl performance,
  }) async {
    _createTypeSystemIfNotLinkingDartCore();

    await performance.runAsync(
      'computeLibraryScopes',
      (performance) async {
        await _computeLibraryScopes(
          performance: performance,
        );
      },
    );

    _createTypeSystem();
    _resolveTypes();
    _setDefaultSupertypes();

    await performance.runAsync(
      'executeMacroDeclarationsPhase',
      (performance) async {
        await _executeMacroDeclarationsPhase(
          targetElement: null,
          performance: performance,
        );
      },
    );

    _buildClassSyntheticConstructors();
    _replaceConstFieldsIfNoConstConstructor();
    _resolveConstructorFieldFormals();
    _buildEnumChildren();
    _computeFieldPromotability();
    SuperConstructorResolver(this).perform();
    _performTopLevelInference();
    _resolveConstructors();
    _resolveConstantInitializers();
    _resolveDefaultValues();
    _resolveMetadata();

    // TODO(scheglov): verify if any resolutions should happen after
    await performance.runAsync(
      'executeMacroDefinitionsPhase',
      (performance) async {
        await _executeMacroDefinitionsPhase(
          performance: performance,
        );
      },
    );

    _collectMixinSuperInvokedNames();
    _buildElementNameUnions();
    _detachNodes();

    await performance.runAsync(
      'mergeMacroAugmentations',
      (performance) async {
        await _mergeMacroAugmentations(
          performance: performance,
        );
      },
    );
  }

  void _collectMixinSuperInvokedNames() {
    for (var library in builders.values) {
      library.collectMixinSuperInvokedNames();
    }
  }

  void _computeFieldPromotability() {
    for (var library in builders.values) {
      library.computeFieldPromotability();
    }
  }

  Future<void> _computeLibraryScopes({
    required OperationPerformanceImpl performance,
  }) async {
    for (var library in builders.values) {
      library.buildElements();
    }

    await performance.runAsync(
      'buildMacroApplier',
      (performance) async {
        await _buildMacroApplier();
      },
    );

    await performance.runAsync(
      'executeMacroTypesPhase',
      (performance) async {
        for (var library in builders.values) {
          await library.executeMacroTypesPhase(
            performance: performance,
          );
        }
      },
    );

    _buildExportScopes();
  }

  void _createTypeSystem() {
    elementFactory.createTypeProviders(
      elementFactory.dartCoreElement,
      elementFactory.dartAsyncElement,
    );

    inheritance = InheritanceManager3();
  }

  /// To resolve macro annotations we need to access exported namespaces of
  /// imported (and already linked) libraries. While computing it we might
  /// need `Null` from `dart:core` (to convert null safe types to legacy).
  void _createTypeSystemIfNotLinkingDartCore() {
    if (!_isLinkingDartCore) {
      _createTypeSystem();
    }
  }

  void _detachNodes() {
    for (var builder in builders.values) {
      detachElementsFromNodes(builder.element);
    }
  }

  Future<void> _executeMacroDeclarationsPhase({
    required ElementImpl? targetElement,
    required OperationPerformanceImpl performance,
  }) async {
    while (true) {
      var hasProgress = false;
      for (final library in builders.values) {
        final stepResult = await library.executeMacroDeclarationsPhase(
          targetElement: targetElement,
          performance: performance,
        );
        switch (stepResult) {
          case MacroDeclarationsPhaseStepResult.nothing:
            break;
          case MacroDeclarationsPhaseStepResult.otherProgress:
            hasProgress = true;
          case MacroDeclarationsPhaseStepResult.topDeclaration:
            hasProgress = true;
            _buildExportScopes();
        }
      }
      if (!hasProgress) {
        break;
      }
    }
  }

  Future<void> _executeMacroDefinitionsPhase({
    required OperationPerformanceImpl performance,
  }) async {
    for (final library in builders.values) {
      await library.executeMacroDefinitionsPhase(
        performance: performance,
      );
    }
  }

  Future<void> _mergeMacroAugmentations({
    required OperationPerformanceImpl performance,
  }) async {
    for (final library in builders.values) {
      await library.mergeMacroAugmentations(
        performance: performance,
      );
    }
  }

  void _performTopLevelInference() {
    TopLevelInference(this).infer();
  }

  void _replaceConstFieldsIfNoConstConstructor() {
    for (final library in builders.values) {
      library.replaceConstFieldsIfNoConstConstructor();
    }
  }

  void _resolveConstantInitializers() {
    ConstantInitializersResolver(this).perform();
  }

  void _resolveConstructorFieldFormals() {
    for (final library in builders.values) {
      library.resolveConstructorFieldFormals();
    }
  }

  void _resolveConstructors() {
    for (var library in builders.values) {
      library.resolveConstructors();
    }
  }

  void _resolveDefaultValues() {
    for (var library in builders.values) {
      library.resolveDefaultValues();
    }
  }

  void _resolveMetadata() {
    for (var library in builders.values) {
      library.resolveMetadata();
    }
  }

  void _resolveTypes() {
    var nodesToBuildType = NodesToBuildType();
    for (var library in builders.values) {
      library.resolveTypes(nodesToBuildType);
    }
    VarianceBuilder(this).perform();
    computeSimplyBounded(this);
    TypeAliasSelfReferenceFinder().perform(this);
    TypesBuilder(this).build(nodesToBuildType);
  }

  void _setDefaultSupertypes() {
    for (final library in builders.values) {
      library.setDefaultSupertypes();
    }
  }

  void _writeLibraries() {
    var bundleWriter = BundleWriter(
      elementFactory.dynamicRef,
    );

    for (var builder in builders.values) {
      bundleWriter.writeLibraryElement(builder.element);
    }

    var writeWriterResult = bundleWriter.finish();
    resolutionBytes = writeWriterResult.resolutionBytes;
  }
}

class LinkResult {
  final Uint8List resolutionBytes;

  LinkResult({
    required this.resolutionBytes,
  });
}
