// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/type_algebra.dart';
import 'package:kernel/type_environment.dart';

import 'list_factory_specializer.dart';

void transformLibraries(List<Library> libraries, CoreTypes coreTypes,
    ClassHierarchy hierarchy, DiagnosticReporter diagnosticReporter) {
  final transformer =
      _WasmTransformer(coreTypes, hierarchy, diagnosticReporter);
  libraries.forEach(transformer.visitLibrary);
}

void transformProcedure(
    Procedure procedure, CoreTypes coreTypes, ClassHierarchy hierarchy) {
  final transformer = _WasmTransformer(coreTypes, hierarchy, null);
  procedure.accept(transformer);
}

class _WasmTransformer extends Transformer {
  final TypeEnvironment env;
  final DiagnosticReporter? diagnosticReporter;

  Member? _currentMember;
  StaticTypeContext? _cachedTypeContext;

  final Library _coreLibrary;
  final InterfaceType _nonNullableTypeType;

  final Class _completerClass;
  final Class _streamControllerClass;
  final Class _wasmArrayClass;
  final Class _wasmBaseClass;

  final Procedure _completerComplete;
  final Procedure _completerConstructor;
  final Procedure _completerGetFuture;
  final Procedure _streamControllerAdd;
  final Procedure _streamControllerAddError;
  final Procedure _streamControllerAddStream;
  final Procedure _streamControllerClose;
  final Procedure _streamControllerConstructor;
  final Procedure _streamControllerGetHasListener;
  final Procedure _streamControllerGetIsPaused;
  final Procedure _streamControllerGetStream;
  final Procedure _streamControllerSetOnCancel;
  final Procedure _streamControllerSetOnListen;
  final Procedure _streamControllerSetOnResume;

  final List<_AsyncStarFrame> _asyncStarFrames = [];
  bool _enclosingIsAsyncStar = false;

  final ListFactorySpecializer _listFactorySpecializer;

  StaticTypeContext get typeContext =>
      _cachedTypeContext ??= StaticTypeContext(_currentMember!, env);

  CoreTypes get coreTypes => env.coreTypes;

  _WasmTransformer(
      CoreTypes coreTypes, ClassHierarchy hierarchy, this.diagnosticReporter)
      : env = TypeEnvironment(coreTypes, hierarchy),
        _nonNullableTypeType = coreTypes.index
            .getClass('dart:core', '_Type')
            .getThisType(coreTypes, Nullability.nonNullable),
        _coreLibrary = coreTypes.index.getLibrary('dart:core'),
        _completerClass = coreTypes.index.getClass('dart:async', 'Completer'),
        _streamControllerClass =
            coreTypes.index.getClass('dart:async', 'StreamController'),
        _wasmArrayClass = coreTypes.index.getClass('dart:_wasm', 'WasmArray'),
        _wasmBaseClass = coreTypes.index.getClass('dart:_wasm', '_WasmBase'),
        _completerComplete =
            coreTypes.index.getProcedure('dart:async', 'Completer', 'complete'),
        _completerConstructor =
            coreTypes.index.getProcedure('dart:async', 'Completer', ''),
        _completerGetFuture = coreTypes.index
            .getProcedure('dart:async', 'Completer', 'get:future'),
        _streamControllerAdd = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'add'),
        _streamControllerAddError = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'addError'),
        _streamControllerAddStream = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'addStream'),
        _streamControllerClose = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'close'),
        _streamControllerConstructor =
            coreTypes.index.getProcedure('dart:async', 'StreamController', ''),
        _streamControllerGetHasListener = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'get:hasListener'),
        _streamControllerGetIsPaused = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'get:isPaused'),
        _streamControllerGetStream = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'get:stream'),
        _streamControllerSetOnCancel = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'set:onCancel'),
        _streamControllerSetOnListen = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'set:onListen'),
        _streamControllerSetOnResume = coreTypes.index
            .getProcedure('dart:async', 'StreamController', 'set:onResume'),
        _listFactorySpecializer = ListFactorySpecializer(coreTypes);

  @override
  defaultMember(Member node) {
    _currentMember = node;
    _cachedTypeContext = null;

    final result = super.defaultMember(node);

    _currentMember = null;
    _cachedTypeContext = null;
    return result;
  }

  /// Checks to see if it is safe to reuse `super._typeArguments`.
  bool canReuseSuperMethod(Class cls) {
    // We search for the first non-abstract super in [cls]'s inheritance chain
    // to see if we can reuse its `_typeArguments` method.
    Class classIter = cls;
    late Supertype supertype;
    while (classIter.supertype != null) {
      Supertype supertypeIter = classIter.supertype!;
      Class superclass = supertypeIter.classNode;
      if (!superclass.isAbstract) {
        supertype = supertypeIter;
        break;
      }
      classIter = classIter.supertype!.classNode;
    }

    // We can reuse a superclass' `_typeArguments` method if the subclass and
    // the superclass have the exact same type parameters in the exact same
    // order.
    if (cls.typeParameters.length != supertype.typeArguments.length) {
      return false;
    }
    for (int i = 0; i < cls.typeParameters.length; i++) {
      TypeParameter parameter = cls.typeParameters[i];
      DartType arg = supertype.typeArguments[i];
      if (arg is! TypeParameterType || arg.parameter != parameter) {
        return false;
      }
    }
    return true;
  }

  @override
  TreeNode visitClass(Class cls) {
    // For every concrete class whose type parameters do not match the type
    // parameters of it's super class we embed a special virtual function
    // `_getTypeArguments`.  When generating code for `_getTypeArguments`, we
    // read the `TypeParameter`s off the instantiated object and generate a
    // `List<Type>` to pass to `_getRuntimeType` which then returns a reified
    // `Type` object.
    if (!cls.isAbstract &&
        cls != coreTypes.objectClass &&
        !env.hierarchy.isSubclassOf(cls, _wasmBaseClass) &&
        !canReuseSuperMethod(cls)) {
      Procedure getTypeArguments = Procedure(
          Name("_typeArguments", _coreLibrary),
          ProcedureKind.Getter,
          FunctionNode(
            null,
            returnType: InterfaceType(_wasmArrayClass, Nullability.nonNullable,
                [_nonNullableTypeType]),
          ),
          isExternal: true,
          isSynthetic: true,
          fileUri: cls.fileUri)
        ..isNonNullableByDefault = true;
      cls.addProcedure(getTypeArguments);
    }
    return super.visitClass(cls);
  }

  TreeNode _lowerForIn(ForInStatement stmt) {
    // Transform
    //
    //   for ({var/final} T <variable> in <iterable>) { ... }
    //
    // Into
    //
    //  {
    //    final Iterator<T> #forIterator = <iterable>.iterator;
    //    for (; #forIterator.moveNext() ;) {
    //        {var/final} T variable = #forIterator.current;
    //        ...
    //      }
    //    }
    //  }
    //
    // and:
    //
    //   await for ({var/final} T <variable> in <stream>) { ... }
    //
    // Into
    //
    //  {
    //    final StreamIterator<T> #forIterator = StreamIterator(<stream>);
    //    bool #jumpSentinel = false;
    //    try {
    //      for (; jumpSentinel = await #forIterator.moveNext() ;) {
    //        {var/final} T variable = #forIterator.current;
    //        ...
    //      }
    //    } finally {
    //      if (#jumpSentinel) {
    //        await #forIterator.cancel();
    //      }
    //    }
    //  }

    // The CFE might invoke this transformation despite the program having
    // compile-time errors. So we will not transform this [stmt] if the
    // `stmt.iterable` is an invalid expression or has an invalid type and
    // instead eliminate the entire for-in and replace it with a invalid
    // expression statement.
    final iterable = stmt.iterable;
    final iterableType = iterable.getStaticType(typeContext);
    if (iterableType is InvalidType) {
      return ExpressionStatement(
          InvalidExpression('Invalid iterable type in for-in'));
    }

    final isAsync = stmt.isAsync;
    late final Class iteratorClass;
    late final Procedure iteratorMoveNext;
    late final Member iteratorCurrent;
    if (isAsync) {
      iteratorClass = coreTypes.streamIteratorClass;
      iteratorMoveNext = coreTypes.streamIteratorMoveNext;
      iteratorCurrent = coreTypes.streamIteratorCurrent;
    } else {
      iteratorClass = coreTypes.iteratorClass;
      iteratorMoveNext = coreTypes.iteratorMoveNext;
      iteratorCurrent = coreTypes.iteratorGetCurrent;
    }

    final DartType elementType = stmt.getElementType(typeContext);
    final iteratorType =
        InterfaceType(iteratorClass, Nullability.nonNullable, [elementType]);

    late final Expression iteratorInitializer;
    if (isAsync) {
      iteratorInitializer = ConstructorInvocation(
          coreTypes.streamIteratorDefaultConstructor,
          Arguments([iterable], types: [elementType]));
    } else {
      iteratorInitializer = InstanceGet(
          InstanceAccessKind.Instance, iterable, Name('iterator'),
          interfaceTarget: coreTypes.iterableGetIterator,
          resultType: iteratorType);
    }

    final iterator = VariableDeclaration("#forIterator",
        initializer: iteratorInitializer..fileOffset = iterable.fileOffset,
        type: iteratorType,
        isSynthesized: true)
      ..fileOffset = iterable.fileOffset;

    // Only used when `isAsync` is true.
    final jumpSentinel = VariableDeclaration("#jumpSentinel",
        initializer: ConstantExpression(BoolConstant(false)),
        type: InterfaceType(coreTypes.boolClass, Nullability.nonNullable),
        isSynthesized: true);

    final condition = InstanceInvocation(InstanceAccessKind.Instance,
        VariableGet(iterator), Name('moveNext'), Arguments(const []),
        interfaceTarget: iteratorMoveNext,
        functionType: iteratorMoveNext.getterType as FunctionType)
      ..fileOffset = iterable.fileOffset;

    final variable = stmt.variable
      ..initializer = (InstanceGet(
          InstanceAccessKind.Instance, VariableGet(iterator), Name('current'),
          interfaceTarget: iteratorCurrent, resultType: elementType)
        ..fileOffset = stmt.bodyOffset);

    Block body = Block([variable, stmt.body])..fileOffset = stmt.fileOffset;

    Statement forStatement = ForStatement(
        const [],
        isAsync
            ? VariableSet(jumpSentinel, AwaitExpression(condition))
            : condition,
        const [],
        body);

    // Wrap the body with a try / finally to cancel the stream on breaking out
    // of the loop.
    if (isAsync) {
      forStatement = TryFinally(
        Block([forStatement]),
        Block([
          IfStatement(
              VariableGet(jumpSentinel),
              ExpressionStatement(AwaitExpression(InstanceInvocation(
                  InstanceAccessKind.Instance,
                  VariableGet(iterator),
                  Name('cancel'),
                  Arguments(const []),
                  interfaceTarget: coreTypes.streamIteratorCancel,
                  functionType: coreTypes.streamIteratorCancel.getterType
                      as FunctionType))),
              null)
        ]),
      );
    }

    return Block([iterator, if (isAsync) jumpSentinel, forStatement])
        .accept<TreeNode>(this);
  }

  @override
  TreeNode visitForInStatement(ForInStatement stmt) {
    return _lowerForIn(stmt);
  }

  InstanceInvocation _addToController(
      VariableDeclaration controller, Expression expression, int fileOffset) {
    final controllerNullableObjectType = InterfaceType(_streamControllerClass,
        Nullability.nonNullable, [coreTypes.objectNullableRawType]);
    FunctionType controllerAddType =
        Substitution.fromInterfaceType(controllerNullableObjectType)
                .substituteType(_streamControllerAdd.function
                    .computeThisFunctionType(Nullability.nonNullable))
            as FunctionType;
    return InstanceInvocation(InstanceAccessKind.Instance,
        VariableGet(controller), Name('add'), Arguments([expression]),
        interfaceTarget: _streamControllerAdd, functionType: controllerAddType)
      ..fileOffset = fileOffset;
  }

  TreeNode _lowerAsyncStar(FunctionNode functionNode) {
    // Convert the function into:
    //
    //    Stream<T> name(args) {
    //      var #controller = StreamController<T>(sync: true);
    //
    //      void #body() async {
    //        Completer<void>? #paused;
    //
    //        #controller.onResume = #controller.onCancel = () {
    //          #paused?.complete(null);
    //          #paused = null;
    //        };
    //
    //        try {
    //          <transformed body>
    //        } catch (e, s) {
    //          #controller.addError(e, s);
    //        } finally {
    //          #controller.close();
    //        }
    //      }
    //
    //      #controller.onListen = () {
    //        scheduleMicrotask(#body);
    //      };
    //
    //      return controller.stream;
    //    }
    //
    // Where `<transformed body>` is the body of `functionNode` with these
    // transformations:
    //
    // - yield* e
    //
    //   ==>
    //
    //   await #controller.addStream(e);
    //   if (!#controller.hasListener) {
    //     return;
    //   }
    //
    // - yield e
    //
    //   ==>
    //
    //   #controller.add(e);
    //   if (#controller.isPaused) {
    //     await (#paused = Completer()).future;
    //   }
    //   if (!#controller.hasListener) {
    //     return;
    //   }
    //
    // The `yield` and `yield*` transformations are done by [visitYieldStatement].

    final fileOffset = functionNode.fileOffset;
    final emittedValueType = functionNode.emittedValueType!;

    // var #controller = StreamController<T>(sync: true);
    final controllerObjectType = InterfaceType(
        _streamControllerClass, Nullability.nonNullable, [emittedValueType]);

    // StreamController<T>(sync: true)
    final controllerInitializer = StaticInvocation(
        _streamControllerConstructor,
        Arguments([], types: [
          emittedValueType
        ], named: [
          NamedExpression('sync', ConstantExpression(BoolConstant(true)))
        ]));

    // var #controller = ...
    final controllerVar = VariableDeclaration('#controller',
        initializer: controllerInitializer..fileOffset = fileOffset,
        type: controllerObjectType,
        isSynthesized: true)
      ..fileOffset = fileOffset;

    // `void #body() async { ... }` statements.
    final List<Statement> bodyStatements = [];

    // Completer<void>? #paused;
    final pausedVarType = InterfaceType(
        _completerClass, Nullability.nullable, [const VoidType()]);

    final pausedVar = VariableDeclaration('#paused',
        initializer: null, type: pausedVarType, isSynthesized: true);

    bodyStatements.add(pausedVar);

    // controller.onResume = controller.onCancel = () {
    //   #paused?.complete(null);
    //   #paused = null;
    // };
    final List<Statement> onCancelCallbackBodyStatements = [
      IfStatement(
          EqualsNull(VariableGet(pausedVar)),
          Block([]),
          Block([
            ExpressionStatement(InstanceInvocation(
              InstanceAccessKind.Instance,
              VariableGet(pausedVar),
              Name('complete'),
              Arguments([ConstantExpression(NullConstant())]),
              interfaceTarget: _completerComplete,
              functionType: substitute(_completerComplete.getterType, {
                _completerClass.typeParameters.first: const VoidType()
              }) as FunctionType,
            )),
            ExpressionStatement(VariableSet(
              pausedVar,
              ConstantExpression(NullConstant()),
            ))
          ])),
    ];

    final onCancelCallback = FunctionExpression(FunctionNode(
      Block(onCancelCallbackBodyStatements),
      typeParameters: [],
      positionalParameters: [],
      namedParameters: [],
      requiredParameterCount: 0,
      returnType: const VoidType(),
    ));

    final onCancelCallbackVar =
        VariableDeclaration("#onCancelCallback", initializer: onCancelCallback);

    bodyStatements.add(onCancelCallbackVar);

    bodyStatements.add(ExpressionStatement(InstanceSet(
        InstanceAccessKind.Instance,
        VariableGet(controllerVar),
        Name('onResume'),
        VariableGet(onCancelCallbackVar),
        interfaceTarget: _streamControllerSetOnResume)));

    bodyStatements.add(ExpressionStatement(InstanceSet(
        InstanceAccessKind.Instance,
        VariableGet(controllerVar),
        Name('onCancel'),
        VariableGet(onCancelCallbackVar),
        interfaceTarget: _streamControllerSetOnCancel)));

    _asyncStarFrames
        .add(_AsyncStarFrame(controllerVar, pausedVar, emittedValueType));
    final Statement transformedBody =
        functionNode.body!.accept<TreeNode>(this) as Statement;
    _asyncStarFrames.removeLast();

    // The body will be wrapped with a `try-catch` to pass the error to the
    // controller, and `try-finally` to close the controller.
    final exceptionVar = VariableDeclaration(null, isSynthesized: true);

    final stackTraceVar = VariableDeclaration(null,
        isSynthesized: true,
        type: coreTypes.stackTraceRawType(Nullability.nonNullable));

    final catch_ = Catch(
        exceptionVar,
        stackTrace: stackTraceVar,
        ExpressionStatement(InstanceInvocation(
          InstanceAccessKind.Instance,
          VariableGet(controllerVar),
          Name("addError"),
          Arguments([VariableGet(exceptionVar), VariableGet(stackTraceVar)]),
          interfaceTarget: _streamControllerAddError,
          functionType: _streamControllerAddError.getterType as FunctionType,
        )));

    final finalizer = ExpressionStatement(InstanceInvocation(
      InstanceAccessKind.Instance,
      VariableGet(controllerVar),
      Name("close"),
      Arguments([]),
      interfaceTarget: _streamControllerClose,
      functionType: _streamControllerClose.getterType as FunctionType,
    ));

    bodyStatements
        .add(TryFinally(TryCatch(transformedBody, [catch_]), finalizer));

    final bodyFunction = FunctionNode(Block(bodyStatements),
        emittedValueType: const VoidType(),
        returnType: InterfaceType(
            coreTypes.futureClass, Nullability.nonNullable, [const VoidType()]),
        asyncMarker: AsyncMarker.Async,
        dartAsyncMarker: AsyncMarker.Async);

    final bodyInitializer = FunctionExpression(bodyFunction);

    final bodyFunctionType =
        bodyFunction.computeThisFunctionType(Nullability.nonNullable);

    final bodyVar = VariableDeclaration('#body',
        initializer: bodyInitializer..fileOffset = fileOffset,
        type: bodyFunctionType,
        isSynthesized: true)
      ..fileOffset = fileOffset;

    // controller.onListen = () {
    //   scheduleMicrotask(_body);
    // };
    final scheduleMicrotaskProcedure =
        coreTypes.index.getTopLevelProcedure('dart:async', 'scheduleMicrotask');

    final setControllerOnListen = InstanceSet(
        InstanceAccessKind.Instance,
        VariableGet(controllerVar),
        Name('onListen'),
        FunctionExpression(FunctionNode(ExpressionStatement(StaticInvocation(
            scheduleMicrotaskProcedure, Arguments([VariableGet(bodyVar)]))))),
        interfaceTarget: _streamControllerSetOnListen);

    return FunctionNode(
        Block([
          // var controller = StreamController<T>(sync: true);
          controllerVar,

          // var #body = ...;
          bodyVar,

          // controller.onListen = ...;
          ExpressionStatement(setControllerOnListen),

          // return controller.stream;
          ReturnStatement(InstanceGet(
            InstanceAccessKind.Instance,
            VariableGet(controllerVar),
            Name("stream"),
            interfaceTarget: _streamControllerGetStream,
            resultType: substitute(_streamControllerGetStream.getterType, {
              _streamControllerClass.typeParameters.first: emittedValueType,
            }),
          ))
        ]),
        typeParameters: functionNode.typeParameters,
        positionalParameters: functionNode.positionalParameters,
        namedParameters: functionNode.namedParameters,
        requiredParameterCount: functionNode.requiredParameterCount,
        returnType: functionNode.returnType,
        asyncMarker: AsyncMarker.Sync,
        dartAsyncMarker: AsyncMarker.Sync);
  }

  @override
  TreeNode visitYieldStatement(YieldStatement yield) {
    // We currently ignore yields in 'sync*'.
    if (!_enclosingIsAsyncStar) {
      return super.visitYieldStatement(yield);
    }

    final fileOffset = yield.fileOffset;
    final frame = _asyncStarFrames.last;
    final controllerVar = frame.controllerVar;
    final pausedVar = frame.pausedVar;
    final isYieldStar = yield.isYieldStar;

    final transformedExpression = yield.expression.accept(this) as Expression;

    final List<Statement> statements = [];

    if (isYieldStar) {
      // yield* e
      //
      // ==>
      //
      // await #controller.addStream(e);
      // if (!#controller.hasListener) return;

      final controllerAddStreamProcedureType =
          _streamControllerAddStream.getterType as FunctionType;

      statements.add(ExpressionStatement(AwaitExpression(InstanceInvocation(
        InstanceAccessKind.Instance,
        VariableGet(controllerVar),
        Name('addStream'),
        Arguments([transformedExpression]),
        interfaceTarget: _streamControllerAddStream,
        functionType: substitute(controllerAddStreamProcedureType, {
          _streamControllerClass.typeParameters.first: frame.emittedValueType,
        }) as FunctionType,
      ))));

      statements.add(IfStatement(
          InstanceGet(InstanceAccessKind.Instance, VariableGet(controllerVar),
              Name('hasListener'),
              interfaceTarget: _streamControllerGetHasListener,
              resultType: coreTypes.boolNonNullableRawType),
          Block([]),
          ReturnStatement()));
    } else {
      // yield e
      //
      // ==>
      //
      // #controller.add(e);
      // if (#controller.isPaused) {
      //   await (#paused = Completer()).future;
      // }
      // if (!#controller.hasListener) {
      //   return;
      // }

      statements.add(ExpressionStatement(
          _addToController(controllerVar, yield.expression, fileOffset)));

      // if (controller.isPaused) ...
      statements.add(IfStatement(
          InstanceGet(InstanceAccessKind.Instance, VariableGet(controllerVar),
              Name('isPaused'),
              interfaceTarget: _streamControllerGetIsPaused,
              resultType: coreTypes.boolNonNullableRawType),
          ExpressionStatement(AwaitExpression(InstanceGet(
              InstanceAccessKind.Instance,
              VariableSet(
                  pausedVar,
                  StaticInvocation(_completerConstructor,
                      Arguments([], types: [const VoidType()]))),
              Name('future'),
              interfaceTarget: _completerGetFuture,
              resultType: substitute(_completerGetFuture.getterType,
                  {_completerClass.typeParameters.first: const VoidType()})))),
          null));

      // if (!controller.hasListener) return;
      statements.add(IfStatement(
        InstanceGet(InstanceAccessKind.Instance, VariableGet(controllerVar),
            Name('hasListener'),
            interfaceTarget: _streamControllerGetHasListener,
            resultType: coreTypes.boolNonNullableRawType),
        Block([]),
        ReturnStatement(),
      ));
    }

    return Block(statements);
  }

  @override
  TreeNode visitFunctionNode(FunctionNode functionNode) {
    final previousEnclosing = _enclosingIsAsyncStar;
    if (functionNode.dartAsyncMarker == AsyncMarker.AsyncStar) {
      _enclosingIsAsyncStar = true;
      functionNode = _lowerAsyncStar(functionNode) as FunctionNode;
      _enclosingIsAsyncStar = previousEnclosing;
      return super.visitFunctionNode(functionNode);
    } else {
      _enclosingIsAsyncStar = false;
      TreeNode result = super.visitFunctionNode(functionNode);
      _enclosingIsAsyncStar = previousEnclosing;
      return result;
    }
  }

  @override
  TreeNode visitStaticInvocation(StaticInvocation node) {
    node.transformChildren(this);
    return _listFactorySpecializer.transformStaticInvocation(node);
  }

  @override
  visitFunctionTearOff(FunctionTearOff node) {
    node.transformChildren(this);
    return node.receiver;
  }
}

class _AsyncStarFrame {
  final VariableDeclaration controllerVar;
  final VariableDeclaration pausedVar;
  final DartType emittedValueType;

  _AsyncStarFrame(this.controllerVar, this.pausedVar, this.emittedValueType);
}
