import 'dart:async';

import 'package:graphql_parser/graphql_parser.dart';
import 'schema/schema.dart';

import 'introspection.dart';

export 'package:graphql_parser/graphql_parser.dart';
export 'schema/schema.dart';

/// Transforms any [Map] into `Map<String, dynamic>`.
Map<String, dynamic> foldToStringDynamic(Map map) {
  return map == null
      ? null
      : map.keys.fold<Map<String, dynamic>>(
          <String, dynamic>{}, (out, k) => out..[k.toString()] = map[k]);
}

/// A Dart implementation of a GraphQL server.
class GraphQL {
  /// Any custom types to include in introspection information.
  final List<GraphQLType> customTypes = [];

  // ignore: lines_longer_than_80_chars
  /// An optional callback that can be used to resolve fields from objects that are not [Map]s,
  /// when the related field has no resolver.
  final FutureOr<T> Function<T>(T, String, Map<String, dynamic>)
      defaultFieldResolver;

  GraphQLSchema _schema;

  /// Constructor
  GraphQL(GraphQLSchema schema,
      {bool introspect = true,
      this.defaultFieldResolver,
      List<GraphQLType> customTypes = const <GraphQLType>[]})
      : _schema = schema {
    if (customTypes?.isNotEmpty == true) {
      this.customTypes.addAll(customTypes);
    }

    if (introspect) {
      final allTypes = <GraphQLType>[]..addAll(this.customTypes);
      _schema = reflectSchema(_schema, allTypes);

      for (var type in allTypes.toSet()) {
        if (!this.customTypes.contains(type)) {
          this.customTypes.add(type);
        }
      }
    }

    if (_schema.queryType != null) this.customTypes.add(_schema.queryType);
    if (_schema.mutationType != null) {
      this.customTypes.add(_schema.mutationType);
    }
    if (_schema.subscriptionType != null) {
      this.customTypes.add(_schema.subscriptionType);
    }
  }

  // ignore: public_member_api_docs
  GraphQLType convertType(TypeContext ctx) {
    if (ctx.listType != null) {
      return GraphQLListType(convertType(ctx.listType.type));
    } else if (ctx.typeName != null) {
      switch (ctx.typeName.name) {
        case 'Int':
          return graphQLString;
        case 'Float':
          return graphQLFloat;
        case 'String':
          return graphQLString;
        case 'Boolean':
          return graphQLBoolean;
        case 'ID':
          return graphQLId;
        case 'Date':
        case 'DateTime':
          return graphQLDate;
        default:
          return customTypes.firstWhere((t) => t.name == ctx.typeName.name,
              orElse: () => throw ArgumentError(
                  'Unknown GraphQL type: "${ctx.typeName.name}"'));
      }
    } else {
      throw ArgumentError('Invalid GraphQL type: "${ctx.span.text}"');
    }
  }

  /// parseAndExecute - run.
  Future parseAndExecute(String text,
      {String operationName,
      Object sourceUrl,
      Map<String, dynamic> variableValues = const {},
      Object initialValue,
      Map<String, dynamic> globalVariables}) {
    final tokens = scan(text, sourceUrl: sourceUrl);
    final parser = Parser(tokens);
    final document = parser.parseDocument();

    if (parser.errors.isNotEmpty) {
      throw GraphQLException(parser.errors
          .map((e) => GraphQLExceptionError(e.message, locations: [
                GraphExceptionErrorLocation.fromSourceLocation(e.span.start)
              ]))
          .toList());
    }

    return executeRequest(
      _schema,
      document,
      operationName: operationName,
      initialValue: initialValue,
      variableValues: variableValues,
      globalVariables: globalVariables,
    );
  }

  // ignore: public_member_api_docs
  Future executeRequest(GraphQLSchema schema, DocumentContext document,
      {String operationName,
      Map<String, dynamic> variableValues = const <String, dynamic>{},
      Object initialValue,
      Map<String, dynamic> globalVariables = const <String, dynamic>{}}) async {
    final operation = getOperation(document, operationName);
    final coercedVariableValues = coerceVariableValues(
        schema, operation, variableValues ?? <String, dynamic>{});
    if (operation.isQuery)
      return await executeQuery(document, operation, schema,
          coercedVariableValues, initialValue, globalVariables);
    else if (operation.isSubscription) {
      return await subscribe(document, operation, schema, coercedVariableValues,
          globalVariables, initialValue);
    } else {
      return executeMutation(document, operation, schema, coercedVariableValues,
          initialValue, globalVariables);
    }
  }

  // ignore: public_member_api_docs
  OperationDefinitionContext getOperation(
      DocumentContext document, String operationName) {
    final ops =
        // ignore: prefer_iterable_wheretype
        document.definitions.where((d) => d is OperationDefinitionContext);

    if (operationName == null) {
      return ops.length == 1
          ? ops.first as OperationDefinitionContext
          : throw GraphQLException.fromMessage(
              'This document does not define any operations.');
    } else {
      return ops.firstWhere(
              (d) => (d as OperationDefinitionContext).name == operationName,
              orElse: () => throw GraphQLException.fromMessage(
                  'Missing required operation "$operationName".'))
          as OperationDefinitionContext;
    }
  }

  // ignore: public_member_api_docs
  Map<String, dynamic> coerceVariableValues(
      GraphQLSchema schema,
      OperationDefinitionContext operation,
      Map<String, dynamic> variableValues) {
    final coercedValues = <String, dynamic>{};
    final variableDefinitions =
        operation.variableDefinitions?.variableDefinitions ?? [];

    for (var variableDefinition in variableDefinitions) {
      final variableName = variableDefinition.variable.name;
      final variableType = variableDefinition.type;
      final defaultValue = variableDefinition.defaultValue;
      final value = variableValues[variableName];

      if (value == null) {
        if (defaultValue != null) {
          coercedValues[variableName] = defaultValue.value.value;
        } else if (!variableType.isNullable) {
          throw GraphQLException.fromSourceSpan(
              'Missing required variable "$variableName".',
              variableDefinition.span);
        }
      } else {
        final type = convertType(variableType);
        final validation = type.validate(variableName, value);

        if (!validation.successful) {
          throw GraphQLException(validation.errors
              .map((e) => GraphQLExceptionError(e, locations: [
                    GraphExceptionErrorLocation.fromSourceLocation(
                        variableDefinition.span.start)
                  ]))
              .toList());
        } else {
          coercedValues[variableName] = type.deserialize(value);
        }
      }
    }

    return coercedValues;
  }

  // ignore: public_member_api_docs
  Future<Map<String, dynamic>> executeQuery(
      DocumentContext document,
      OperationDefinitionContext query,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      Object initialValue,
      Map<String, dynamic> globalVariables) async {
    final queryType = schema.queryType;
    final selectionSet = query.selectionSet;
    return await executeSelectionSet(document, selectionSet, queryType,
        initialValue, variableValues, globalVariables);
  }

  // ignore: public_member_api_docs
  Future<Map<String, dynamic>> executeMutation(
      DocumentContext document,
      OperationDefinitionContext mutation,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      Object initialValue,
      Map<String, dynamic> globalVariables) async {
    final mutationType = schema.mutationType;

    if (mutationType == null) {
      throw GraphQLException.fromMessage(
          'The schema does not define a mutation type.');
    }

    final selectionSet = mutation.selectionSet;
    return await executeSelectionSet(document, selectionSet, mutationType,
        initialValue, variableValues, globalVariables);
  }

  // ignore: public_member_api_docs
  Future<Stream<Map<String, dynamic>>> subscribe(
      DocumentContext document,
      OperationDefinitionContext subscription,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables,
      Object initialValue) async {
    final sourceStream = await createSourceEventStream(
        document, subscription, schema, variableValues, initialValue);
    return mapSourceToResponseEvent(sourceStream, subscription, schema,
        document, initialValue, variableValues, globalVariables);
  }

  // ignore: public_member_api_docs
  Future<Stream> createSourceEventStream(
      DocumentContext document,
      OperationDefinitionContext subscription,
      GraphQLSchema schema,
      Map<String, dynamic> variableValues,
      Object initialValue) {
    final selectionSet = subscription.selectionSet;
    final subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
          'The schema does not define a subscription type.', subscription.span);
    }

    final groupedFieldSet =
        collectFields(document, subscriptionType, selectionSet, variableValues);

    if (groupedFieldSet.length != 1) {
      throw GraphQLException.fromSourceSpan(
          'The grouped field set from this query must have exactly one entry.',
          selectionSet.span);
    }

    final fields = groupedFieldSet.entries.first.value;
    final fieldName = fields.first.field.fieldName.alias?.name ??
        fields.first.field.fieldName.name;
    final field = fields.first;
    final argumentValues =
        coerceArgumentValues(subscriptionType, field, variableValues);
    return resolveFieldEventStream(
        subscriptionType, initialValue, fieldName, argumentValues);
  }

  // ignore: public_member_api_docs
  Stream<Map<String, dynamic>> mapSourceToResponseEvent(
    Stream sourceStream,
    OperationDefinitionContext subscription,
    GraphQLSchema schema,
    DocumentContext document,
    Object initialValue,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables,
  ) async* {
    await for (var event in sourceStream) {
      yield await executeSubscriptionEvent(document, subscription, schema,
          event, variableValues, globalVariables);
    }
  }

  // ignore: public_member_api_docs
  Future<Map<String, dynamic>> executeSubscriptionEvent(
      DocumentContext document,
      OperationDefinitionContext subscription,
      GraphQLSchema schema,
      Object initialValue,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    final selectionSet = subscription.selectionSet;
    final subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
          'The schema does not define a subscription type.', subscription.span);
    }

    try {
      final data = await executeSelectionSet(document, selectionSet,
          subscriptionType, initialValue, variableValues, globalVariables);
      return {'data': data};
    } on GraphQLException catch (e) {
      return {
        'data': null,
        'errors': [e.errors.map((e) => e.toJson()).toList()]
      };
    }
  }

  // ignore: public_member_api_docs
  Future<Stream> resolveFieldEventStream(
      GraphQLObjectType subscriptionType,
      Object rootValue,
      String fieldName,
      Map<String, dynamic> argumentValues) async {
    final field = subscriptionType.fields.firstWhere((f) => f.name == fieldName,
        orElse: () {
      throw GraphQLException.fromMessage(
          'No subscription field named "$fieldName" is defined.');
    });
    final resolver = field.resolve;
    final result = await resolver(rootValue, argumentValues);

    if (result is Stream) {
      return result;
    } else {
      return Stream.fromIterable([result]);
    }
  }

  // ignore: public_member_api_docs
  Future<Map<String, dynamic>> executeSelectionSet(
      DocumentContext document,
      SelectionSetContext selectionSet,
      GraphQLObjectType objectType,
      Object objectValue,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    final groupedFieldSet =
        collectFields(document, objectType, selectionSet, variableValues);
    final resultMap = <String, dynamic>{};

    for (var responseKey in groupedFieldSet.keys) {
      final fields = groupedFieldSet[responseKey];

      for (var field in fields) {
        final fieldName =
            field.field.fieldName.alias?.name ?? field.field.fieldName.name;
        Object responseValue;

        if (fieldName == '__typename') {
          responseValue = objectType.name;
        } else {
          final fieldType = objectType.fields
              .firstWhere((f) => f.name == fieldName, orElse: () => null)
              ?.type;
          if (fieldType == null) continue;
          responseValue = await executeField(
              document,
              fieldName,
              objectType,
              objectValue,
              fields,
              fieldType,
              Map<String, dynamic>.from(globalVariables ?? <String, dynamic>{})
                ..addAll(variableValues),
              globalVariables);
        }

        resultMap[responseKey] = responseValue;
      }
    }

    return resultMap;
  }

  // ignore: public_member_api_docs
  Future executeField(
      DocumentContext document,
      String fieldName,
      GraphQLObjectType objectType,
      Object objectValue,
      List<SelectionContext> fields,
      GraphQLType fieldType,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    final field = fields[0];
    final argumentValues =
        coerceArgumentValues(objectType, field, variableValues);
    final resolvedValue = await resolveFieldValue(
        objectType, objectValue, fieldName, argumentValues);
    return completeValue(document, fieldName, fieldType, fields, resolvedValue,
        variableValues, globalVariables);
  }

  // ignore: public_member_api_docs
  Map<String, dynamic> coerceArgumentValues(GraphQLObjectType objectType,
      SelectionContext field, Map<String, dynamic> variableValues) {
    final coercedValues = <String, dynamic>{};
    final argumentValues = field.field.arguments;
    final fieldName =
        field.field.fieldName.alias?.name ?? field.field.fieldName.name;
    final desiredField = objectType.fields.firstWhere(
        (f) => f.name == fieldName,
        orElse: () => throw FormatException(
            '${objectType.name} has no field named "$fieldName".'));
    final argumentDefinitions = desiredField.inputs;

    for (var argumentDefinition in argumentDefinitions) {
      final argumentName = argumentDefinition.name;
      final argumentType = argumentDefinition.type;
      final defaultValue = argumentDefinition.defaultValue;

      final value = argumentValues.firstWhere((a) => a.name == argumentName,
          orElse: () => null);

      if (value?.valueOrVariable?.variable != null) {
        final variableName = value.valueOrVariable.variable.name;
        final variableValue = variableValues[variableName];

        if (variableValues.containsKey(variableName)) {
          coercedValues[argumentName] = variableValue;
        } else if (defaultValue != null || argumentDefinition.defaultsToNull) {
          coercedValues[argumentName] = defaultValue;
        } else if (argumentType is GraphQLNonNullableType) {
          throw GraphQLException.fromSourceSpan(
              // ignore: lines_longer_than_80_chars
              'Missing value for argument "$argumentName" of field "$fieldName".',
              value.valueOrVariable.span);
        } else {
          continue;
        }
      } else if (value == null) {
        if (defaultValue != null || argumentDefinition.defaultsToNull) {
          coercedValues[argumentName] = defaultValue;
        } else if (argumentType is GraphQLNonNullableType) {
          throw GraphQLException.fromMessage(
              // ignore: lines_longer_than_80_chars
              'Missing value for argument "$argumentName" of field "$fieldName".');
        } else {
          continue;
        }
      } else {
        try {
          final validation = argumentType.validate(
              fieldName, value.valueOrVariable.value.value);

          if (!validation.successful) {
            final errors = <GraphQLExceptionError>[
              GraphQLExceptionError(
                // ignore: lines_longer_than_80_chars
                'Type coercion error for value of argument "$argumentName" of field "$fieldName".',
                locations: [
                  GraphExceptionErrorLocation.fromSourceLocation(
                      value.valueOrVariable.span.start)
                ],
              )
            ];

            for (var error in validation.errors) {
              errors.add(
                GraphQLExceptionError(
                  error,
                  locations: [
                    GraphExceptionErrorLocation.fromSourceLocation(
                        value.valueOrVariable.span.start)
                  ],
                ),
              );
            }

            throw GraphQLException(errors);
          } else {
            final coercedValue = validation.value;
            coercedValues[argumentName] = coercedValue;
          }
          // ignore: avoid_catching_errors
        } on TypeError catch (e) {
          throw GraphQLException(<GraphQLExceptionError>[
            GraphQLExceptionError(
              // ignore: lines_longer_than_80_chars
              'Type coercion error for value of argument "$argumentName" of field "$fieldName".',
              locations: [
                GraphExceptionErrorLocation.fromSourceLocation(
                    value.valueOrVariable.span.start)
              ],
            ),
            GraphQLExceptionError(
              e.message.toString(),
              locations: [
                GraphExceptionErrorLocation.fromSourceLocation(
                    value.valueOrVariable.span.start)
              ],
            ),
          ]);
        }
      }
    }

    return coercedValues;
  }

  // ignore: public_member_api_docs
  Future<T> resolveFieldValue<T>(GraphQLObjectType objectType, T objectValue,
      String fieldName, Map<String, dynamic> argumentValues) async {
    final field = objectType.fields.firstWhere((f) => f.name == fieldName);

    if (objectValue is Map) {
      return objectValue[fieldName] as T;
    } else if (field.resolve == null) {
      if (defaultFieldResolver != null) {
        return await defaultFieldResolver(
            objectValue, fieldName, argumentValues);
      }

      return null;
    } else {
      return await field.resolve(objectValue, argumentValues) as T;
    }
  }

  // ignore: public_member_api_docs
  Future completeValue(
      DocumentContext document,
      String fieldName,
      GraphQLType fieldType,
      List<SelectionContext> fields,
      Object result,
      Map<String, dynamic> variableValues,
      Map<String, dynamic> globalVariables) async {
    if (fieldType is GraphQLNonNullableType) {
      final innerType = fieldType.ofType;
      final completedResult = await completeValue(document, fieldName,
          innerType, fields, result, variableValues, globalVariables);

      if (completedResult == null) {
        throw GraphQLException.fromMessage(
            'Null value provided for non-nullable field "$fieldName".');
      } else {
        return completedResult;
      }
    }

    if (result == null) {
      return null;
    }

    if (fieldType is GraphQLListType) {
      if (result is! Iterable) {
        throw GraphQLException.fromMessage(
            // ignore: lines_longer_than_80_chars
            'Value of field "$fieldName" must be a list or iterable, got $result instead.');
      }

      final innerType = fieldType.ofType;
      final out = [];

      // ignore: unnecessary_parenthesis
      for (var resultItem in (result as Iterable)) {
        out.add(await completeValue(document, '(item in "$fieldName")',
            innerType, fields, resultItem, variableValues, globalVariables));
      }

      return out;
    }

    if (fieldType is GraphQLScalarType) {
      try {
        final validation = fieldType.validate(fieldName, result);

        if (!validation.successful) {
          return null;
        } else {
          return validation.value;
        }
        // ignore: avoid_catching_errors
      } on TypeError {
        throw GraphQLException.fromMessage(
            // ignore: lines_longer_than_80_chars
            'Value of field "$fieldName" must be ${fieldType.valueType}, got $result instead.');
      }
    }

    if (fieldType is GraphQLObjectType || fieldType is GraphQLUnionType) {
      GraphQLObjectType objectType;

      if (fieldType is GraphQLObjectType && !fieldType.isInterface) {
        objectType = fieldType;
      } else {
        objectType = resolveAbstractType(fieldName, fieldType, result);
      }

      final subSelectionSet = mergeSelectionSets(fields);
      return await executeSelectionSet(document, subSelectionSet, objectType,
          result, variableValues, globalVariables);
    }

    throw UnsupportedError('Unsupported type: $fieldType');
  }

  // ignore: public_member_api_docs
  GraphQLObjectType resolveAbstractType(
      String fieldName, GraphQLType type, Object result) {
    List<GraphQLObjectType> possibleTypes;

    if (type is GraphQLObjectType) {
      if (type.isInterface) {
        possibleTypes = type.possibleTypes;
      } else {
        return type;
      }
    } else if (type is GraphQLUnionType) {
      possibleTypes = type.possibleTypes;
    } else {
      throw ArgumentError();
    }

    final errors = <GraphQLExceptionError>[];

    for (var t in possibleTypes) {
      try {
        final validation =
            t.validate(fieldName, foldToStringDynamic(result as Map));

        if (validation.successful) {
          return t;
        }

        errors.addAll(validation.errors.map((m) => GraphQLExceptionError(m)));
      } on GraphQLException catch (e) {
        errors.addAll(e.errors);
      }
    }

    errors.insert(0,
        GraphQLExceptionError('Cannot convert value $result to type $type.'));

    throw GraphQLException(errors);
  }

  // ignore: public_member_api_docs
  SelectionSetContext mergeSelectionSets(List<SelectionContext> fields) {
    final selections = <SelectionContext>[];

    for (var field in fields) {
      if (field.field?.selectionSet != null) {
        selections.addAll(field.field.selectionSet.selections);
      } else if (field.inlineFragment?.selectionSet != null) {
        selections.addAll(field.inlineFragment.selectionSet.selections);
      }
    }

    return SelectionSetContext.merged(selections);
  }

  // ignore: public_member_api_docs
  Map<String, List<SelectionContext>> collectFields(
      DocumentContext document,
      GraphQLObjectType objectType,
      SelectionSetContext selectionSet,
      Map<String, dynamic> variableValues,
      {List visitedFragments}) {
    final groupedFields = <String, List<SelectionContext>>{};
    visitedFragments ??= [];

    for (var selection in selectionSet.selections) {
      if (getDirectiveValue('skip', 'if', selection, variableValues) == true) {
        continue;
      }

      if (getDirectiveValue('include', 'if', selection, variableValues) ==
          false) continue;

      if (selection.field != null) {
        final responseKey = selection.field.fieldName.alias?.alias ??
            selection.field.fieldName.name;
        groupedFields.putIfAbsent(responseKey, () => []).add(selection);
      } else if (selection.fragmentSpread != null) {
        final fragmentSpreadName = selection.fragmentSpread.name;
        if (visitedFragments.contains(fragmentSpreadName)) continue;
        visitedFragments.add(fragmentSpreadName);
        final fragment = document.definitions
            // ignore: prefer_iterable_wheretype
            .where((d) => d is FragmentDefinitionContext)
            .firstWhere(
                (f) =>
                    (f as FragmentDefinitionContext).name == fragmentSpreadName,
                orElse: () => null) as FragmentDefinitionContext;

        if (fragment == null) continue;
        final fragmentType = fragment.typeCondition;
        if (!doesFragmentTypeApply(objectType, fragmentType)) continue;
        final fragmentSelectionSet = fragment.selectionSet;
        final fragmentGroupFieldSet = collectFields(
            document, objectType, fragmentSelectionSet, variableValues);

        for (var responseKey in fragmentGroupFieldSet.keys) {
          final fragmentGroup = fragmentGroupFieldSet[responseKey];
          groupedFields
              .putIfAbsent(responseKey, () => [])
              .addAll(fragmentGroup);
        }
      } else if (selection.inlineFragment != null) {
        final fragmentType = selection.inlineFragment.typeCondition;
        if (fragmentType != null &&
            !doesFragmentTypeApply(objectType, fragmentType)) continue;
        final fragmentSelectionSet = selection.inlineFragment.selectionSet;
        final fragmentGroupFieldSet = collectFields(
            document, objectType, fragmentSelectionSet, variableValues);

        for (var responseKey in fragmentGroupFieldSet.keys) {
          final fragmentGroup = fragmentGroupFieldSet[responseKey];
          groupedFields
              .putIfAbsent(responseKey, () => [])
              .addAll(fragmentGroup);
        }
      }
    }

    return groupedFields;
  }

  // ignore: public_member_api_docs, type_annotate_public_apis, always_declare_return_types
  getDirectiveValue(String name, String argumentName,
      SelectionContext selection, Map<String, dynamic> variableValues) {
    if (selection.field == null) return null;
    final directive = selection.field.directives.firstWhere((d) {
      final vv = d.valueOrVariable;
      if (vv.value != null) return vv.value.value == name;
      return vv.variable.name == name;
    }, orElse: () => null);

    if (directive == null) return null;
    if (directive.argument?.name != argumentName) return null;

    final vv = directive.argument.valueOrVariable;

    if (vv.value != null) return vv.value.value;

    final vname = vv.variable.name;
    if (!variableValues.containsKey(vname)) {
      throw GraphQLException.fromSourceSpan(
          'Unknown variable: "$vname"', vv.span);
    }

    return variableValues[vname];
  }

  // ignore: public_member_api_docs
  bool doesFragmentTypeApply(
      GraphQLObjectType objectType, TypeConditionContext fragmentType) {
    final type = convertType(TypeContext(fragmentType.typeName, null));
    if (type is GraphQLObjectType && !type.isInterface) {
      for (var field in type.fields) {
        if (!objectType.fields.any((f) => f.name == field.name)) return false;
      }

      return true;
    } else if (type is GraphQLObjectType && type.isInterface) {
      return objectType.isImplementationOf(type);
    } else if (type is GraphQLUnionType) {
      return type.possibleTypes.any((t) => objectType.isImplementationOf(t));
    }

    return false;
  }
}
