import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/server_config.dart';
import '../services/Config/config_service.dart';
import '../services/Telemetry/telemetry.dart';

abstract class ConfigEvent {}

class LoadConfig extends ConfigEvent {}

class SaveConfig extends ConfigEvent {
  final ServerConfig config;
  SaveConfig(this.config);
}

abstract class ConfigState {}

class ConfigInitial extends ConfigState {}

class ConfigLoaded extends ConfigState {
  final ServerConfig config;
  ConfigLoaded(this.config);
}

class ConfigBloc extends Bloc<ConfigEvent, ConfigState> {
  final ConfigService service;
  ConfigBloc(this.service) : super(ConfigInitial()) {
    on<LoadConfig>((event, emit) async {
      final span = Telemetry.instance.tracer.startSpan('load_config');
      final c = await service.load();
      span.end();
      emit(ConfigLoaded(c));
    });
    on<SaveConfig>((event, emit) async {
      final span = Telemetry.instance.tracer.startSpan('save_config');
      await service.save(event.config);
      span.end();
      emit(ConfigLoaded(event.config));
    });
  }
}
