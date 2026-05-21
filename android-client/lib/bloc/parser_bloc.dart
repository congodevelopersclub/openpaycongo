import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/parser_source.dart';
import '../services/Parsers/parser_store.dart';
import '../services/Telemetry/telemetry.dart';

abstract class ParserEvent {}

class LoadParsers extends ParserEvent {}

class AddParser extends ParserEvent {
  final String name;
  final String regex;
  AddParser(this.name, this.regex);
}

abstract class ParserState {}

class ParserInitial extends ParserState {}

class ParserLoaded extends ParserState {
  final List<ParserSource> parsers;
  ParserLoaded(this.parsers);
}

class ParserBloc extends Bloc<ParserEvent, ParserState> {
  final ParserStore store;
  ParserBloc(this.store) : super(ParserInitial()) {
    on<LoadParsers>((event, emit) async {
      final span = Telemetry.instance.tracer.startSpan('load_parsers');
      final parsers = await store.all();
      span.end();
      emit(ParserLoaded(parsers));
    });
    on<AddParser>((event, emit) async {
      final span = Telemetry.instance.tracer.startSpan('add_parser');
      await store.insert(ParserSource(name: event.name, regex: event.regex));
      final parsers = await store.all();
      span.end();
      emit(ParserLoaded(parsers));
    });
  }
}
