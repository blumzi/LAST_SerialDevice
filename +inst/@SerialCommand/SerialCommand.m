classdef SerialCommand < handle
    properties
        Command     string
        NeedsReply  logical
    end

    methods
        function Obj = SerialCommand(cmd, tf)
            Obj.Command = cmd;
            Obj.NeedsReply = tf;
        end
    end
end