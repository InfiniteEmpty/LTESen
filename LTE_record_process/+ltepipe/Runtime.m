classdef Runtime < handle
%RUNTIME Shared initialization context and infrastructure services.

    properties (Access = private)
        Context
        Services
    end

    methods
        function obj = Runtime()
            obj.Context = struct();
            obj.Services = struct();
        end

        function setContext(obj, key, value)
            key = obj.validateKey(key);
            obj.Context.(key) = value;
        end

        function value = getContext(obj, key)
            key = obj.validateKey(key);
            if ~isfield(obj.Context, key)
                error('ltepipe:Runtime:MissingContext', ...
                    'Runtime context "%s" is not available.', key);
            end
            value = obj.Context.(key);
        end

        function addService(obj, key, value)
            key = obj.validateKey(key);
            if isfield(obj.Services, key)
                error('ltepipe:Runtime:DuplicateService', ...
                    'Runtime service "%s" is already registered.', key);
            end
            obj.Services.(key) = value;
        end

        function value = getService(obj, key)
            key = obj.validateKey(key);
            if ~isfield(obj.Services, key)
                error('ltepipe:Runtime:MissingService', ...
                    'Runtime service "%s" is not available.', key);
            end
            value = obj.Services.(key);
        end

        function status = getStatus(obj)
            status = struct('ContextKeys', {fieldnames(obj.Context).'}, ...
                'Services', struct());
            serviceKeys = fieldnames(obj.Services);
            for index = 1:numel(serviceKeys)
                key = serviceKeys{index};
                service = obj.Services.(key);
                if ismethod(service, 'getStatus')
                    status.Services.(key) = service.getStatus();
                else
                    status.Services.(key) = struct( ...
                        'Class', class(service));
                end
            end
        end
    end

    methods (Static, Access = private)
        function key = validateKey(key)
            key = char(string(key));
            if ~isvarname(key)
                error('ltepipe:Runtime:InvalidKey', ...
                    'Runtime keys must be valid MATLAB identifiers.');
            end
        end
    end
end
