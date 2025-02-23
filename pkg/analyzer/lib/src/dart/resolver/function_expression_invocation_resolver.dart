// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/resolver/extension_member_resolver.dart';
import 'package:analyzer/src/dart/resolver/invocation_inference_helper.dart';
import 'package:analyzer/src/dart/resolver/invocation_inferrer.dart';
import 'package:analyzer/src/dart/resolver/type_property_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/nullable_dereference_verifier.dart';
import 'package:analyzer/src/generated/resolver.dart';

/// Helper for resolving [FunctionExpressionInvocation]s.
class FunctionExpressionInvocationResolver {
  final ResolverVisitor _resolver;
  final TypePropertyResolver _typePropertyResolver;
  final InvocationInferenceHelper _inferenceHelper;

  FunctionExpressionInvocationResolver({
    required ResolverVisitor resolver,
  })  : _resolver = resolver,
        _typePropertyResolver = resolver.typePropertyResolver,
        _inferenceHelper = resolver.inferenceHelper;

  ErrorReporter get _errorReporter => _resolver.errorReporter;

  ExtensionMemberResolver get _extensionResolver => _resolver.extensionResolver;

  NullableDereferenceVerifier get _nullableDereferenceVerifier =>
      _resolver.nullableDereferenceVerifier;

  void resolve(FunctionExpressionInvocationImpl node,
      List<WhyNotPromotedGetter> whyNotPromotedList,
      {required DartType contextType}) {
    var function = node.function;

    if (function is ExtensionOverrideImpl) {
      _resolveReceiverExtensionOverride(node, function, whyNotPromotedList,
          contextType: contextType);
      return;
    }

    var receiverType = function.typeOrThrow;
    if (_checkForUseOfVoidResult(function, receiverType)) {
      _unresolved(node, DynamicTypeImpl.instance, whyNotPromotedList,
          contextType: contextType);
      return;
    }

    if (receiverType is FunctionType) {
      _nullableDereferenceVerifier.expression(
        CompileTimeErrorCode.UNCHECKED_INVOCATION_OF_NULLABLE_VALUE,
        function,
      );
      _resolve(node, receiverType, whyNotPromotedList,
          contextType: contextType);
      return;
    }

    if (identical(receiverType, NeverTypeImpl.instance)) {
      _errorReporter.atNode(
        function,
        WarningCode.RECEIVER_OF_TYPE_NEVER,
      );
      _unresolved(node, NeverTypeImpl.instance, whyNotPromotedList,
          contextType: contextType);
      return;
    }

    var result = _typePropertyResolver.resolve(
      receiver: function,
      receiverType: receiverType,
      name: FunctionElement.CALL_METHOD_NAME,
      propertyErrorEntity: function,
      nameErrorEntity: function,
    );
    var callElement = result.getter;

    if (callElement == null) {
      if (result.needsGetterError) {
        _errorReporter.atNode(
          function,
          CompileTimeErrorCode.INVOCATION_OF_NON_FUNCTION_EXPRESSION,
        );
      }
      final type = result.isGetterInvalid
          ? InvalidTypeImpl.instance
          : DynamicTypeImpl.instance;
      _unresolved(node, type, whyNotPromotedList, contextType: contextType);
      return;
    }

    if (callElement.kind != ElementKind.METHOD) {
      _errorReporter.atNode(
        function,
        CompileTimeErrorCode.INVOCATION_OF_NON_FUNCTION_EXPRESSION,
      );
      _unresolved(node, InvalidTypeImpl.instance, whyNotPromotedList,
          contextType: contextType);
      return;
    }

    node.staticElement = callElement;
    var rawType = callElement.type;
    _resolve(node, rawType, whyNotPromotedList, contextType: contextType);
  }

  /// Check for situations where the result of a method or function is used,
  /// when it returns 'void'. Or, in rare cases, when other types of expressions
  /// are void, such as identifiers.
  ///
  /// See [CompileTimeErrorCode.USE_OF_VOID_RESULT].
  ///
  // TODO(scheglov): this is duplicate
  bool _checkForUseOfVoidResult(Expression expression, DartType type) {
    if (!identical(type, VoidTypeImpl.instance)) {
      return false;
    }

    if (expression is MethodInvocation) {
      SimpleIdentifier methodName = expression.methodName;
      _errorReporter.atNode(
        methodName,
        CompileTimeErrorCode.USE_OF_VOID_RESULT,
      );
    } else {
      _errorReporter.atNode(
        expression,
        CompileTimeErrorCode.USE_OF_VOID_RESULT,
      );
    }

    return true;
  }

  void _resolve(FunctionExpressionInvocationImpl node, FunctionType rawType,
      List<WhyNotPromotedGetter> whyNotPromotedList,
      {required DartType contextType}) {
    var returnType = FunctionExpressionInvocationInferrer(
      resolver: _resolver,
      node: node,
      argumentList: node.argumentList,
      whyNotPromotedList: whyNotPromotedList,
      contextType: contextType,
    ).resolveInvocation(rawType: rawType);

    _inferenceHelper.recordStaticType(node, returnType);
  }

  void _resolveReceiverExtensionOverride(FunctionExpressionInvocationImpl node,
      ExtensionOverride function, List<WhyNotPromotedGetter> whyNotPromotedList,
      {required DartType contextType}) {
    var result = _extensionResolver.getOverrideMember(
      function,
      FunctionElement.CALL_METHOD_NAME,
    );
    var callElement = result.getter;
    node.staticElement = callElement;

    if (callElement == null) {
      _errorReporter.atNode(
        function,
        CompileTimeErrorCode.INVOCATION_OF_EXTENSION_WITHOUT_CALL,
        arguments: [function.name.lexeme],
      );
      return _unresolved(node, DynamicTypeImpl.instance, whyNotPromotedList,
          contextType: contextType);
    }

    if (callElement.isStatic) {
      _errorReporter.atNode(
        node.argumentList,
        CompileTimeErrorCode.EXTENSION_OVERRIDE_ACCESS_TO_STATIC_MEMBER,
      );
    }

    var rawType = callElement.type;
    _resolve(node, rawType, whyNotPromotedList, contextType: contextType);
  }

  void _unresolved(FunctionExpressionInvocationImpl node, DartType type,
      List<WhyNotPromotedGetter> whyNotPromotedList,
      {required DartType contextType}) {
    _setExplicitTypeArgumentTypes(node);
    FunctionExpressionInvocationInferrer(
            resolver: _resolver,
            node: node,
            argumentList: node.argumentList,
            contextType: contextType,
            whyNotPromotedList: whyNotPromotedList)
        .resolveInvocation(rawType: null);
    node.staticInvokeType = type;
    node.staticType = type;
  }

  /// Inference cannot be done, we still want to fill type argument types.
  static void _setExplicitTypeArgumentTypes(
    FunctionExpressionInvocationImpl node,
  ) {
    var typeArguments = node.typeArguments;
    if (typeArguments != null) {
      node.typeArgumentTypes = typeArguments.arguments
          .map((typeArgument) => typeArgument.typeOrThrow)
          .toList();
    } else {
      node.typeArgumentTypes = const <DartType>[];
    }
  }
}
