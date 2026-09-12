function printStatus(status)
%PRINTSTATUS Print nested pipeline status without collapsing structs.

if ~isstruct(status) || ~isscalar(status)
    error('ltepipe:printStatus:InvalidStatus', ...
        'Pipeline status must be a scalar struct.');
end

fprintf('Pipeline status:\n');
summaryFields = {'State', 'Iterations', 'Initialized', ...
    'Finalized', 'TerminationReason'};
for index = 1:numel(summaryFields)
    field = summaryFields{index};
    if isfield(status, field)
        printNamedValue(field, status.(field), 2);
    end
end

fprintf('  Modules (%d):\n', numel(status.Modules));
for index = 1:numel(status.Modules)
    module = status.Modules(index);
    fprintf('    [%d] %s (%s)\n', ...
        index, module.Name, module.Class);
    printStructFields(module.Status, 6);
end

fprintf('  Runtime:\n');
printStructFields(status.Runtime, 4);

fprintf('  FinalArtifacts (%d):\n', numel(status.FinalArtifacts));
for index = 1:numel(status.FinalArtifacts)
    fprintf('    [%d]\n', index);
    printValue(status.FinalArtifacts{index}, 6);
end
if isempty(status.FinalArtifacts)
    fprintf('    (none)\n');
end
end

function printStructFields(value, indent)
if ~isstruct(value) || ~isscalar(value)
    printValue(value, indent);
    return;
end
fields = fieldnames(value);
if isempty(fields)
    fprintf('%s(empty struct)\n', spaces(indent));
    return;
end
for index = 1:numel(fields)
    field = fields{index};
    printNamedValue(field, value.(field), indent);
end
end

function printNamedValue(name, value, indent)
if isExpandable(value)
    fprintf('%s%s:\n', spaces(indent), name);
    printValue(value, indent+2);
else
    fprintf('%s%s: %s\n', ...
        spaces(indent), name, formatLeaf(value));
end
end

function printValue(value, indent)
if isstruct(value)
    if isempty(value)
        fprintf('%s(empty struct)\n', spaces(indent));
    elseif isscalar(value)
        printStructFields(value, indent);
    else
        for index = 1:numel(value)
            fprintf('%s[%d]\n', spaces(indent), index);
            printStructFields(value(index), indent+2);
        end
    end
elseif iscell(value)
    if isempty(value)
        fprintf('%s(none)\n', spaces(indent));
    else
        for index = 1:numel(value)
            fprintf('%s{%d}\n', spaces(indent), index);
            printValue(value{index}, indent+2);
        end
    end
else
    fprintf('%s%s\n', spaces(indent), formatLeaf(value));
end
end

function value = isExpandable(value)
value = isstruct(value) || ...
    (iscell(value) && ~isShortTextCell(value));
end

function text = formatLeaf(value)
maximumElements = 12;
if ischar(value)
    text = ['''' value ''''];
elseif isstring(value) && isscalar(value)
    text = ['"' char(value) '"'];
elseif isnumeric(value) || islogical(value)
    if numel(value) <= maximumElements
        text = mat2str(value);
    else
        text = sprintf('[%s %s]', sizeText(size(value)), class(value));
    end
elseif isShortTextCell(value)
    quoted = cellfun(@(item) ['''' char(item) ''''], ...
        value, 'UniformOutput', false);
    text = ['{' strjoin(quoted, ', ') '}'];
elseif isempty(value)
    text = sprintf('[empty %s]', class(value));
else
    text = sprintf('[%s %s]', sizeText(size(value)), class(value));
end
end

function value = isShortTextCell(items)
value = iscell(items) && numel(items) <= 12 && ...
    all(cellfun(@(item) ischar(item) || ...
    (isstring(item) && isscalar(item)), items));
end

function text = sizeText(dimensions)
parts = arrayfun(@num2str, dimensions, 'UniformOutput', false);
text = strjoin(parts, 'x');
end

function text = spaces(count)
text = repmat(' ', 1, count);
end
