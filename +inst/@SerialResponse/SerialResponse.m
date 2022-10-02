classdef SerialResponse < handle
    properties
        Value
        Time datetime
    end

    methods
        function Obj = SerialResponse(v, t)
            if nargin > 0
                Obj.Value = v;
            end

            if nargin > 1 && isdatetime(t)
                Obj.Time = t;
            else
                Obj.Time = datetime('now');
            end
        end
    end
end