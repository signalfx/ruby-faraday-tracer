require 'spec_helper'

RSpec.describe Faraday::Tracer do
  let(:tracer) { OpenTracingTestTracer.build }

  shared_examples 'tracing' do |request_method|
    let(:make_request) { method(request_method) }

    it 'uses upcase HTTP method as span operation name' do
      make_request.call(method: :post)
      expect(tracer.spans.count).to eq(1)
      expect(tracer.spans.first.operation_name).to eq('POST')
    end

    it 'uses provided span_name as span operation name' do
      span_name = 'custom span name'
      make_request.call(method: :post, span_name: span_name)
      expect(tracer.spans.count).to eq(1)
      expect(tracer.spans.first.operation_name).to eq(span_name)
    end

    it 'sets span.kind to client' do
      make_request.call(method: :post)
      expect(tracer.spans.first.tags).to include({'span.kind' => 'client'})
    end

    it 'sets peer.service when service_name is provided' do
      service_name = 'service-name'
      make_request.call(method: :post, service_name: service_name)
      expect(tracer.spans.first.tags).to include({'peer.service' => service_name})
    end

    describe 'parent_span' do
      it 'allows to pass a pre-created parent span' do
        parent_span = tracer.start_span('parent_span')
        make_request.call(method: :post, span: parent_span)
        span = tracer.spans.last
        expect(span.context.parent_id).to eq(parent_span.context.span_id)
        expect(span.context.trace_id).to eq(parent_span.context.trace_id)
      end

      it 'allows to pass a block as a parent span provider' do
        parent_span = tracer.start_span('parent_span')
        parent_span_provider = -> { parent_span }

        make_request.call(method: :post, span: parent_span_provider)
        span = tracer.spans.last
        expect(span.context.parent_id).to eq(parent_span.context.span_id)
        expect(span.context.trace_id).to eq(parent_span.context.trace_id)
      end
    end

    describe 'error handling' do
      it 'finishes the span' do
        make_request.call(status_code: 502, body: 'Service Unavailable')
        puts tracer.spans.last
        expect(tracer.spans.first.end_time).to_not be_nil
      end

      it 'does not mark span as failed for <500 status' do
        make_request.call(status_code: 401, body: 'Unauthorized')
        expect(tracer.spans.first.tags).not_to include(:error) 
      end

      it 'marks the span as failed for 5xx status' do
        make_request.call(status_code: 502, body: 'Service Unavailable')
        expect(tracer.spans.first.tags).to include({'error' => true})
      end

      it 'records the error' do
        make_request.call(status_code: 502, body: 'Service Unavailable')
        expect(tracer.spans.first.tags).to include({'error' => true})
      end
    end

    describe 'exception handling' do
      it 'finishes the span and records the error' do
        exception = Timeout::Error.new
        expect { make_request.call(app: ->(_env) { raise exception }) }.to raise_error(exception)
        expect(tracer.spans.first.end_time).to_not be_nil
        expect(tracer.spans.first.tags).to include({
          'error' => true,
          'sfx.error.kind' => exception.class.to_s,
          'sfx.error.message' => 'Timeout::Error',
          'sfx.error.stack' => exception.backtrace.join('\n')
        })
      end

      it 're-raise original exception' do
        exception = Timeout::Error.new
        expect { make_request.call(app: ->(_env) { raise exception }) }.to raise_error(exception)
      end
    end
  end

  context 'when span is defined using the builder' do
    include_examples 'tracing', :make_builder_request
  end

  context 'when span is defined in the request context' do
    include_examples 'tracing', :make_explicit_request
  end

  def make_builder_request(options)
    status_code = options.fetch(:status_code, 200)
    body = options.fetch(:body, 'OK')
    app = options.delete(:app) || ->(_app_env) { [status_code, {}, body] }
    request_options = options.slice(:span, :span_name, :service_name)

    connection = Faraday.new do |builder|
      builder.use Faraday::Tracer, request_options.merge(tracer: tracer)
      builder.adapter :test do |stub|
        stub.post('/', &app)
      end
    end

    connection.post('/')
  end

  def make_explicit_request(options)
    status_code = options.fetch(:status_code, 200)
    body = options.fetch(:body, 'OK')
    app = options.delete(:app) || ->(_app_env) { [status_code, {}, body] }
    request_options = options.slice(:span, :span_name, :service_name)

    connection = Faraday.new do |builder|
      builder.use Faraday::Tracer, tracer: tracer
      builder.adapter :test do |stub|
        stub.post('/', &app)
      end
    end

    connection.post('/') do |request|
      request.options.context = request_options
    end
  end
end
