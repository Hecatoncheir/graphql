import 'dart:async';

import 'package:pedantic/pedantic.dart';
import 'package:test/test.dart';

import 'package:graphql/graphql/graphql.dart';

void main() {
  group('GraphQL', () {
    GraphQLObjectType todoType;

    GraphQLObjectType query;
    GraphQLObjectType mutation;
    GraphQLObjectType subscription;

    List<Todo> todos;

    StreamController createdTodoController;
    Stream createdTodo;

    setUp(() {
      todos = <Todo>[];

      todoType = objectType('todo', fields: [
        field(
          'text',
          graphQLString,
          resolve: (obj, args) => obj.text,
        ),
        field(
          'completed',
          graphQLBoolean,
          resolve: (obj, args) => obj.completed,
        ),
      ]);

      query = objectType('TestQuery', fields: [
        field('todos', listOf(todoType),
            inputs: [GraphQLFieldInput('contains', graphQLString)],
            resolve: (_, inputs) =>
                todos.where((todo) => todo.text.contains(inputs['contains']))),
      ]);

      createdTodoController = StreamController();
      createdTodo = createdTodoController.stream.asBroadcastStream();

      mutation = objectType(
        'TestMutation',
        fields: [
          field(
            'todo',
            todoType.nonNullable(),
            description: 'Modifies a todo in the database.',
            inputs: [
              GraphQLFieldInput('text', graphQLString.nonNullable()),
              GraphQLFieldInput('completed', graphQLBoolean.nonNullable()),
            ],
            resolve: (_, inputs) {
              final todo =
                  Todo(text: inputs['text'], completed: inputs['completed']);
              createdTodoController.add(todo);
              todos.add(todo);
              return todo;
            },
          ),
        ],
      );

      subscription = objectType(
        'TestSubscription',
        fields: [
          field('createdTodo', todoType.nonNullable(),
              description: 'Created a todo in the database.',
              resolve: (_, __) => createdTodo
                  .map((todos) => {'createdTodo': todos})
                  .asBroadcastStream()),
        ],
      );
    });

    tearDown(() {
      todos.clear();
    });

    test('query', () async {
      todos.addAll([
        Todo(
          text: 'test',
          completed: false,
        ),
        Todo(
          text: 'text',
          completed: false,
        )
      ]);

      final schema = GraphQLSchema(queryType: query);
      final graphQL = GraphQL(schema);

      const todoContainsTestQuery = '''
      {
        todos(contains: "test") {
           text
        }
      }
      ''';

      final result = await graphQL.parseAndExecute(todoContainsTestQuery);

      expect(result, {
        'todos': [
          {'text': 'test'}
        ]
      });

      const todoContainsTextQuery = '''
      {
        todos(contains: "text") {
           text
        }
      }
      ''';

      final secondResult = await graphQL.parseAndExecute(todoContainsTextQuery);

      expect(secondResult, {
        'todos': [
          {'text': 'text'}
        ]
      });
    });

    test('mutation', () async {
      final schema = GraphQLSchema(queryType: query, mutationType: mutation);
      final graphQL = GraphQL(schema);
      const testMutation = '''
      mutation {
        todo(text: "First todo", completed: false) {
          text
          completed
        }
      }
      ''';

      expect(todos, isEmpty);
      final result = await graphQL.parseAndExecute(testMutation);
      expect(todos, isNotEmpty);
      expect(result['todo']['text'], equals('First todo'));
      expect(result['todo']['completed'], isFalse);
    });

    test('subscription', () async {
      final schema = GraphQLSchema(
          queryType: query,
          mutationType: mutation,
          subscriptionType: subscription);
      final graphQL = GraphQL(schema);

      const testSubscription = '''
      subscription {
        createdTodo {
          text
          completed
        }
      }
      ''';

      final Stream<Map<String, dynamic>> result =
          await graphQL.parseAndExecute(testSubscription);

      const firstTestMutation = '''
          mutation {
            todo(text: "First todo", completed: false) {
              text
              completed
            }
          }
        ''';

      unawaited(graphQL.parseAndExecute(firstTestMutation));

      const secondTestMutation = '''
          mutation {
            todo(text: "Second todo", completed: true) {
              text
              completed
            }
          }
        ''';

      Future.delayed(Duration(seconds: 1),
          () => graphQL.parseAndExecute(secondTestMutation));

      await for (Map<String, dynamic> details in result) {
        if (todos.length == 1) {
          expect(details['data']['createdTodo']['text'], equals('First todo'));
          expect(details['data']['createdTodo']['completed'], isFalse);

          continue;
        }

        if (todos.length == 2) {
          expect(details['data']['createdTodo']['text'], equals('Second todo'));
          expect(details['data']['createdTodo']['completed'], isTrue);

          await createdTodoController.close();
        }
      }
    }, timeout: Timeout(Duration(seconds: 10)));
  });
}

class Todo {
  final String text;
  final bool completed;

  Todo({this.text, this.completed});
}
