import 'package:graphql_parser/graphql_parser.dart';

import 'schema/schema.dart';

// ignore: lines_longer_than_80_chars
/// Performs introspection over a GraphQL [schema], and returns a new one, containing
/// introspective information.
///
// ignore: lines_longer_than_80_chars
/// [allTypes] should contain all types, not directly defined in the schema, that you
/// would like to have introspection available for.
GraphQLSchema reflectSchema(GraphQLSchema schema, List<GraphQLType> allTypes) {
  for (var type in allTypes.toList()) {
    final custom = _fetchAllTypesFromType(type);

    for (var t in custom) {
      if (!allTypes.contains(t)) {
        allTypes.add(t);
      }
    }
  }

  final objectTypes = fetchAllTypes(schema, allTypes);

  final typeType = _reflectSchemaTypes();
  final directiveType = _reflectDirectiveType();
  allTypes.addAll(objectTypes);
  Set<GraphQLType> allTypeSet;

  final schemaType = objectType('__Schema', fields: [
    field(
      'types',
      listOf(typeType),
      resolve: (_, __) => allTypeSet ??= allTypes.toSet(),
    ),
    field(
      'queryType',
      typeType,
      resolve: (_, __) => schema.queryType,
    ),
    field(
      'mutationType',
      typeType,
      resolve: (_, __) => schema.mutationType,
    ),
    field(
      'subscriptionType',
      typeType,
      resolve: (_, __) => schema.subscriptionType,
    ),
    field(
      'directives',
      listOf(directiveType).nonNullable(),
      resolve: (_, __) => [], // TODO: Actually fetch directives
    ),
  ]);

  allTypes.addAll([
    graphQLBoolean,
    graphQLString,
    graphQLId,
    graphQLDate,
    graphQLFloat,
    graphQLInt,
    directiveType,
    typeType,
    schemaType,
    _typeKindType,
    _directiveLocationType,
    _reflectFields(),
    _reflectDirectiveType(),
    _reflectInputValueType(),
    _reflectEnumValueType(),
  ]);

  final fields = <GraphQLObjectField>[
    field(
      '__schema',
      schemaType,
      resolve: (_, __) => schemaType,
    ),
    field(
      '__type',
      typeType,
      inputs: [GraphQLFieldInput('name', graphQLString.nonNullable())],
      resolve: (_, args) {
        final name = args['name'] as String;
        return allTypes.firstWhere((t) => t.name == name,
            orElse: () => throw GraphQLException.fromMessage(
                'No type named "$name" exists.'));
      },
    ),
  ]..addAll(schema.queryType.fields);

  return GraphQLSchema(
    queryType: objectType(schema.queryType.name, fields: fields),
    mutationType: schema.mutationType,
    subscriptionType: schema.subscriptionType,
  );
}

GraphQLObjectType _typeType;

GraphQLObjectType _reflectSchemaTypes() {
  if (_typeType == null) {
    _typeType = _createTypeType();
    _typeType.fields.add(
      field(
        'ofType',
        _reflectSchemaTypes(),
        resolve: (type, _) {
          if (type is GraphQLListType)
            return type.ofType;
          else if (type is GraphQLNonNullableType) return type.ofType;
          return null;
        },
      ),
    );

    _typeType.fields.add(
      field(
        'interfaces',
        listOf(_reflectSchemaTypes().nonNullable()),
        resolve: (type, _) {
          if (type is GraphQLObjectType) {
            return type.interfaces;
          } else {
            return <GraphQLType>[];
          }
        },
      ),
    );

    _typeType.fields.add(
      field(
        'possibleTypes',
        listOf(_reflectSchemaTypes().nonNullable()),
        resolve: (type, _) {
          if (type is GraphQLObjectType && type.isInterface) {
            return type.possibleTypes;
          } else if (type is GraphQLUnionType) {
            return type.possibleTypes;
          } else {
            return null;
          }
        },
      ),
    );

    final fieldType = _reflectFields();
    final inputValueType = _reflectInputValueType();
    var typeField = fieldType.fields
        .firstWhere((f) => f.name == 'type', orElse: () => null);

    if (typeField == null) {
      fieldType.fields.add(
        field(
          'type',
          _reflectSchemaTypes(),
          resolve: (f, _) => (f as GraphQLObjectField).type,
        ),
      );
    }

    typeField = inputValueType.fields
        .firstWhere((f) => f.name == 'type', orElse: () => null);

    if (typeField == null) {
      inputValueType.fields.add(
        field(
          'type',
          _reflectSchemaTypes(),
          resolve: (f, _) =>
              _fetchFromInputValue(f, (f) => f.type, (f) => f.type),
        ),
      );
    }
  }

  return _typeType;
}

final GraphQLEnumType<String> _typeKindType =
    enumTypeFromStrings('__TypeKind', [
  'SCALAR',
  'OBJECT',
  'INTERFACE',
  'UNION',
  'ENUM',
  'INPUT_OBJECT',
  'LIST',
  'NON_NULL'
]);

GraphQLObjectType _createTypeType() {
  final enumValueType = _reflectEnumValueType();
  final fieldType = _reflectFields();
  final inputValueType = _reflectInputValueType();

  return objectType('__Type', fields: [
    field(
      'name',
      graphQLString,
      resolve: (type, _) => (type as GraphQLType).name,
    ),
    field(
      'description',
      graphQLString,
      resolve: (type, _) => (type as GraphQLType).description,
    ),
    field(
      'kind',
      _typeKindType,
      resolve: (type, _) {
        final t = type as GraphQLType;

        if (t is GraphQLEnumType)
          return 'ENUM';
        else if (t is GraphQLScalarType)
          return 'SCALAR';
        else if (t is GraphQLInputObjectType)
          return 'INPUT_OBJECT';
        else if (t is GraphQLObjectType)
          return t.isInterface ? 'INTERFACE' : 'OBJECT';
        else if (t is GraphQLListType)
          return 'LIST';
        else if (t is GraphQLNonNullableType)
          return 'NON_NULL';
        else if (t is GraphQLUnionType) {
          return 'UNION';
        } else {
          throw UnsupportedError('Cannot get the kind of $t.');
        }
      },
    ),
    field(
      'fields',
      listOf(fieldType),
      inputs: [
        GraphQLFieldInput(
          'includeDeprecated',
          graphQLBoolean,
          defaultValue: false,
        ),
      ],
      resolve: (type, args) => type is GraphQLObjectType
          ? type.fields
              .where(
                  (f) => !f.isDeprecated || args['includeDeprecated'] == true)
              .toList()
          : null,
    ),
    field(
      'enumValues',
      listOf(enumValueType.nonNullable()),
      inputs: [
        GraphQLFieldInput(
          'includeDeprecated',
          graphQLBoolean,
          defaultValue: false,
        ),
      ],
      resolve: (obj, args) {
        if (obj is GraphQLEnumType) {
          return obj.values
              .where(
                  (f) => !f.isDeprecated || args['includeDeprecated'] == true)
              .toList();
        } else {
          return null;
        }
      },
    ),
    field(
      'inputFields',
      listOf(inputValueType.nonNullable()),
      resolve: (obj, _) {
        if (obj is GraphQLInputObjectType) {
          return obj.inputFields;
        }

        return null;
      },
    ),
  ]);
}

GraphQLObjectType _fieldType;

GraphQLObjectType _reflectFields() {
  return _fieldType ??= _createFieldType();
}

GraphQLObjectType _createFieldType() {
  final inputValueType = _reflectInputValueType();

  return objectType('__Field', fields: [
    field(
      'name',
      graphQLString,
      resolve: (f, _) => (f as GraphQLObjectField).name,
    ),
    field(
      'description',
      graphQLString,
      resolve: (f, _) => (f as GraphQLObjectField).description,
    ),
    field(
      'isDeprecated',
      graphQLBoolean,
      resolve: (f, _) => (f as GraphQLObjectField).isDeprecated,
    ),
    field(
      'deprecationReason',
      graphQLString,
      resolve: (f, _) => (f as GraphQLObjectField).deprecationReason,
    ),
    field(
      'args',
      listOf(inputValueType.nonNullable()).nonNullable(),
      resolve: (f, _) => (f as GraphQLObjectField).inputs,
    ),
  ]);
}

GraphQLObjectType _inputValueType;

T _fetchFromInputValue<T>(x, T Function(GraphQLFieldInput) ifInput,
    T Function(GraphQLInputObjectField) ifObjectField) {
  if (x is GraphQLFieldInput) {
    return ifInput(x);
  } else if (x is GraphQLInputObjectField) {
    return ifObjectField(x);
  } else {
    return null;
  }
}

GraphQLObjectType _reflectInputValueType() {
  return _inputValueType ??= objectType('__InputValue', fields: [
    field(
      'name',
      graphQLString.nonNullable(),
      resolve: (obj, _) =>
          _fetchFromInputValue(obj, (f) => f.name, (f) => f.name),
    ),
    field(
      'description',
      graphQLString,
      resolve: (obj, _) =>
          _fetchFromInputValue(obj, (f) => f.description, (f) => f.description),
    ),
    field(
      'defaultValue',
      graphQLString,
      resolve: (obj, _) => _fetchFromInputValue(obj,
          (f) => f.defaultValue?.toString(), (f) => f.defaultValue?.toString()),
    ),
  ]);
}

GraphQLObjectType _directiveType;

final GraphQLEnumType<String> _directiveLocationType =
    enumTypeFromStrings('__DirectiveLocation', [
  'QUERY',
  'MUTATION',
  'FIELD',
  'FRAGMENT_DEFINITION',
  'FRAGMENT_SPREAD',
  'INLINE_FRAGMENT'
]);

GraphQLObjectType _reflectDirectiveType() {
  final inputValueType = _reflectInputValueType();

  // TODO: What actually is this???
  return _directiveType ??= objectType('__Directive', fields: [
    field(
      'name',
      graphQLString.nonNullable(),
      resolve: (obj, _) => (obj as DirectiveContext).NAME.span.text,
    ),
    field(
      'description',
      graphQLString,
      resolve: (obj, _) => null,
    ),
    field(
      'locations',
      listOf(_directiveLocationType.nonNullable()).nonNullable(),
      // TODO: Fetch directiveLocation
      resolve: (obj, _) => <String>[],
    ),
    field(
      'args',
      listOf(inputValueType.nonNullable()).nonNullable(),
      resolve: (obj, _) => [],
    ),
  ]);
}

GraphQLObjectType _enumValueType;

GraphQLObjectType _reflectEnumValueType() {
  return _enumValueType ??= objectType(
    '__EnumValue',
    fields: [
      field(
        'name',
        graphQLString.nonNullable(),
        resolve: (obj, _) => (obj as GraphQLEnumValue).name,
      ),
      field(
        'description',
        graphQLString,
        resolve: (obj, _) => (obj as GraphQLEnumValue).description,
      ),
      field(
        'isDeprecated',
        graphQLBoolean.nonNullable(),
        resolve: (obj, _) => (obj as GraphQLEnumValue).isDeprecated,
      ),
      field(
        'deprecationReason',
        graphQLString,
        resolve: (obj, _) => (obj as GraphQLEnumValue).deprecationReason,
      ),
    ],
  );
}

// ignore: public_member_api_docs
List<GraphQLType> fetchAllTypes(
    GraphQLSchema schema, List<GraphQLType> allTypes) {
  final types = <GraphQLType>[]
    ..addAll(_fetchAllTypesFromObject(schema.queryType));

  if (schema.mutationType != null) {
    types.addAll(_fetchAllTypesFromObject(schema.mutationType));
  }

  if (schema.subscriptionType != null) {
    types.addAll(_fetchAllTypesFromObject(schema.subscriptionType));
  }

  return types;
}

List<GraphQLType> _fetchAllTypesFromObject(GraphQLObjectType objectType) {
  final types = <GraphQLType>[objectType];

  for (var field in objectType.fields) {
    if (field.type is GraphQLObjectType) {
      types.addAll(_fetchAllTypesFromObject(field.type as GraphQLObjectType));
    } else if (field.type is GraphQLInputObjectType) {
      for (var v in (field.type as GraphQLInputObjectType).inputFields) {
        types.addAll(_fetchAllTypesFromType(v.type));
      }
    } else {
      types.addAll(_fetchAllTypesFromType(field.type));
    }

    for (var input in field.inputs ?? <GraphQLFieldInput>[]) {
      types.addAll(_fetchAllTypesFromType(input.type));
    }
  }

  for (var i in objectType.interfaces) {
    types.addAll(_fetchAllTypesFromObject(i));
  }

  return types;
}

Iterable<GraphQLType> _fetchAllTypesFromType(GraphQLType type) {
  final types = <GraphQLType>[];

  if (type is GraphQLNonNullableType) {
    types.addAll(_fetchAllTypesFromType(type.ofType));
  } else if (type is GraphQLListType) {
    types.addAll(_fetchAllTypesFromType(type.ofType));
  } else if (type is GraphQLObjectType) {
    types.addAll(_fetchAllTypesFromObject(type));
  } else if (type is GraphQLEnumType) {
    types.add(type);
  } else if (type is GraphQLInputObjectType) {
    for (var v in type.inputFields) {
      types.addAll(_fetchAllTypesFromType(v.type));
    }

    types.add(type);
  } else if (type is GraphQLUnionType) {
    types.add(type);

    for (var t in type.possibleTypes) {
      types.addAll(_fetchAllTypesFromType(t));
    }
  }
  return types;
}
