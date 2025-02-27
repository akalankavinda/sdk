// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/dart/error/syntactic_errors.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../diagnostics/parser_diagnostics.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ExtensionDeclarationParserTest);
  });
}

@reflectiveTest
class ExtensionDeclarationParserTest extends ParserDiagnosticsTest {
  test_augment() {
    final parseResult = parseStringWithErrors(r'''
augment library 'a.dart';

augment extension E {}
''');
    parseResult.assertNoErrors();

    final node = parseResult.findNode.singleExtensionDeclaration;
    assertParsedNodeText(node, r'''
ExtensionDeclaration
  augmentKeyword: augment
  extensionKeyword: extension
  name: E
  leftBracket: {
  rightBracket: }
''');
  }

  test_augment_generic() {
    final parseResult = parseStringWithErrors(r'''
augment library 'a.dart';

augment extension E<T> {}
''');
    parseResult.assertNoErrors();

    final node = parseResult.findNode.singleExtensionDeclaration;
    assertParsedNodeText(node, r'''
ExtensionDeclaration
  augmentKeyword: augment
  extensionKeyword: extension
  name: E
  typeParameters: TypeParameterList
    leftBracket: <
    typeParameters
      TypeParameter
        name: T
    rightBracket: >
  leftBracket: {
  rightBracket: }
''');
  }

  test_augment_hasOnClause() {
    final parseResult = parseStringWithErrors(r'''
augment library 'a.dart';

augment extension E on int {}
''');
    parseResult.assertErrors([
      error(ParserErrorCode.EXTENSION_AUGMENTATION_HAS_ON_CLAUSE, 47, 2),
    ]);

    final node = parseResult.findNode.singleExtensionDeclaration;
    assertParsedNodeText(node, r'''
ExtensionDeclaration
  augmentKeyword: augment
  extensionKeyword: extension
  name: E
  onClause: ExtensionOnClause
    onKeyword: on
    extendedType: NamedType
      name: int
  leftBracket: {
  rightBracket: }
''');
  }
}
