import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';

class Telemetry {
  Telemetry._();
  static final Telemetry instance = Telemetry._();

  late final Tracer tracer;

  Future<void> init() async {
    final exporter = ConsoleExporter();
    final provider = TracerProviderBase(
      processors: [SimpleSpanProcessor(exporter)],
      resource: Resource([Attribute.fromString(ResourceAttributes.serviceName, 'opencongopay')]),
    );
    tracer = provider.getTracer('opencongopay');
    registerGlobalTracerProvider(provider);
  }
}
