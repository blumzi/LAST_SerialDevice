
classdef SerialWorker < handle
    properties
        Connected     logical = false;  % the serialport was successfuly connected
        Monitoring    logical = false;  % periodically get the device's status
        Device;                         % the actual serialport

        PortPath      string;           % serialport path
        PortSpeed     double;           % serialport BaudRate
        Timeout       duration;         % for serialport.readline() or serialport.read()
        Terminator    string = "CR";    % serialport.configureTerminator
        Eol           string = '\r';    % end-of-line string to be discarded
        Interval      duration;         % between status checks
        Validator     function_handle;  % validates replies from the serialport
        Reader        function_handle;  % to be used instead of serialport.readline or serialport.read
        Writer        function_handle;  % to be used instead of serialport.writeline or serialport.write
        ResponseTime  duration;         % how long to wait for a reply from the serialport
        InterCommand  duration;         % delay between multiple commands in the same transaction
        EndOfLoopDelay duration = milliseconds(500);    % delay at the end of the perpetual worker loop (lets the cpu breathe :-)

        StatusCommand  inst.SerialCommand   % a series of SerialCommand(s) to be send every 'Interval' to get the device's status
        Store;
        HasTerminator  logical = false;
    end

    properties(Hidden=true)
        ConnectRetries      double = Inf;
        ConnectRetryDelay   duration = seconds(5);
        Locked              logical = false;
        ExceptionId         string;
        DeviceIsBusy        logical = false;
        LastInteraction     double;
    end

    methods
        function Obj = SerialWorker(WorkerArgs)
% arguments
%     Args.PortPath             string
%     Args.PortSpeed            double = 9600                 % [baud]
%     Args.Timeout              duration                      % [seconds]
%     Args.Terminator           string                        % [char]
%     Args.Interval             duration = milliseconds(20)   % [milliseconds] between status reads
%     Args.ResponseTime         duration = seconds(2)         % [milliseconds] to wait between sending something and getting a response
%     Args.StatusCommand        string                        % [string] to be sent for getting the status
%     Args.Validator            function_handle               % [func] returns true if the response is vallid, throws otherwise
%     Args.Reader               function_handle               % [func] user-specified serial device Reader
%     Args.Writer               function_handle               % [func] user-specified serial device writer
%     Args.InterCommand         duration;                     % [should be duration] to delay between sending a series of commands (millis)
%     Args.ConnectRetries       double;                       % [double] how many times to try to open the serialport (may be Inf)
%     Args.ConnectRetryDelay    duration;                     % [double] delay between connect retries (millis)
%     Args.EndOfLoopDelay       duration = seconds(.5);       % [double] delay at the end of the loop in the worker (millis)
% end

            Args = WorkerArgs(1);
            Func = "SerialWorker: ";
        
            Obj.ExceptionId = 'OCS:SerialWorker';
      
            knownports = serialportlist;
            if isempty(knownports)
                throw(MException(exceptionId,'No serial ports on this machine'));
            end
            
            if isfield(Args, 'PortPath');          Obj.PortPath          = Args.PortPath;                   end 
            if isfield(Args, 'PortSpeed');         Obj.PortSpeed         = Args.PortSpeed;                  end            
            if isfield(Args, 'Terminator');        Obj.Terminator        = Args.Terminator;                 end
            if isfield(Args, 'Timeout');           Obj.Timeout           = Args.Timeout;                    end            
            if isfield(Args, 'Interval');          Obj.Interval          = Args.Interval;                   end            
            if isfield(Args, 'StatusCommand');     Obj.StatusCommand     = Args.StatusCommand;              end
            if isfield(Args, 'Validator');         Obj.Validator         = Args.Validator;                  end
            if isfield(Args, 'Reader');            Obj.Reader            = Args.Reader;                     end
            if isfield(Args, 'Writer');            Obj.Writer            = Args.Writer;                     end
            if isfield(Args, 'ResponseTime');      Obj.ResponseTime      = Args.ResponseTime;               end
            if isfield(Args, 'InterCommand');      Obj.InterCommand      = Args.InterCommand;               end
            if isfield(Args, 'ConnectRetries');    Obj.ConnectRetries    = Args.ConnectRetries;             end
            if isfield(Args, 'ConnectRetryDelay'); Obj.ConnectRetryDelay = Args.ConnectRetryDelay;          end
            if isfield(Args, 'EndOfLoopDelay');    Obj.EndOfLoopDelay    = Args.EndOfLoopDelay;             end

            if isempty(Obj.PortPath)
                throw(MException(Obj.ExceptionId, "Must supply a 'PortPath' argument"));
            end
            if ~ismember(Obj.PortPath, knownports)
                throw(MException(exceptionId,"Unknown device '%s', must be one of [%s]", Args.portPath, strjoin(knownports, ", ")));
            end
            Obj.log(Func + "PortPath: '%s'", Obj.PortPath)
                        
            Obj.HasTerminator = ~isempty(Obj.Terminator);

            % for the time-being, ONLY work with terminated-dialects
            if ~Obj.HasTerminator
                throw(MException(Obj.ExceptionId,'Must specify a terminator'))
            elseif isempty(Obj.Reader)
                Obj.Reader = @serialport.readline;                
            end

            switch Obj.Terminator
                case 'CR'
                    Obj.Eol = '\r';
                case 'LF'
                    Obj.Eol = '\n';
                case 'LF/CR'
                    Obj.Eol = '\n\r';
                case 'CR/LF'
                    Obj.Eol = '\r\n';
            end

            if isempty(Obj.StatusCommand)
                throw(MException(Obj.ExceptionId, "Must supply a 'StatusCommand'"));
            end

            if isempty(Obj.Interval)
                Obj.Interval = milliseconds(5000);
            end

            if isempty(Obj.Timeout)
                Obj.Timeout = seconds(2);
            end
            Obj.Device.Timeout = seconds(Obj.Timeout);

            if isempty(Obj.Reader)
                if ~Obj.HasTerminator
                    Obj.Reader = @serialport.read;
                else
                    Obj.Reader = @serialport.readline;
                end
            end
            
            if isempty(Obj.Writer)
                if ~Obj.HasTerminator
                    Obj.Writer = @internal.SerialPort.write;
                else
                    Obj.Writer = @internal.SerialPort.writeline;
                end
            end
            
            Obj.Store = getCurrentValueStore;
            Obj.DeviceIsBusy = false;

            try
                Obj.loop;
            catch ME
                if Obj.Connected
                    Obj.disconnect
                end
                Obj.Store('exception') = ME;
                quit
            end
        end


        %
        % A serial worker's main loop
        %
        function loop(Obj)

            Func = 'SerialWorker.loop: '; % don't use dbstack() !!!

            Obj.log(Func + "entered");
            
            while true
                
                if isKey(Obj.Store, 'directive')
                    %
                    % Directives are commands to the worker process (not to the device)
                    % A directive is a structure with two fields:
                    %  - Name: the directive itself
                    %  - Value: [optional]
                    %    - if empty:        this is a GET operation
                    %    - if not empty:    this is a SET operation
                    %
                    directive = Obj.Store('directive');
                    msg = sprintf("directive: Name: '%s'", directive.Name);
                    if ~isempty(directive.Value)
                        msg = msg + sprintf(", Value: '%s'", string(directive.Value));
                    else
                        msg = msg + sprintf(", Value: '<empty>'");
                    end
                    Obj.log(Func + msg);
        
                    if strcmp(directive.Name, 'quit')
                        if Obj.Connected
                            Obj.disconnect
                        end
                        remove(Obj.Store, 'directive');
                        return % quit worker, Obj should close the worker process

                    elseif strcmp(directive.Name, "connected")

                        if isempty(directive.Value)  % get value of 'connected'
                            Obj.Store('directive-response') = Obj.Connected;
                            continue;
                        end

                        for attemptNumber = 1:Obj.ConnectRetries
                            try
                                if logical(directive.Value)
                                    % connected = true
                                    Obj.log(Func + "attempt#%d to connect to '%s' at %d", attemptNumber, Obj.PortPath, Obj.PortSpeed);
                                    Obj.Device = serialport(Obj.PortPath, Obj.PortSpeed);
                                    if ~isempty(Obj.Timeout)
                                        Obj.Device.Timeout = seconds(Obj.Timeout);
                                    end
                            
                                    if Obj.HasTerminator
                                        Obj.Device.configureTerminator(Obj.Terminator);
                                        if ~isempty(Obj.Reader)
                                            configureCallback(Obj.Device, 'terminator', @Obj.Reader);
                                        end
                                    end
                                    Obj.Connected = true;
                                    Obj.log(Func + "attempt#%d succeeded", attemptNumber);
                                    break;
                                else
                                    % connected = false
                                    if Obj.Connected
                                        Obj.disconnect
                                    end
                                end
                                Obj.Store('directive-response') = Obj.Connected;

                            catch ME
                                Obj.log(Func + "attempt#%d failed (error: %s)", attemptNumber, ME.message);
                                Obj.Connected = false;
                                Obj.Store('directive-response') = ME;
                            end

                            if ~isempty(Obj.ConnectRetryDelay)
                                pause(seconds(Obj.ConnectRetryDelay))
                            end
                        end

                        Obj.Store('connected') = Obj.Connected;
                        Obj.Store('directive-response') = Obj.Connected;
                        remove(Obj.Store, 'directive');
                        continue;

                    elseif strcmp(directive.Name, 'BaudRate')      % get/set speed
                        try
                            if ~isempty(directive.Value)
                                if isa(directive.Value, 'string')
                                    v = str2num(directive.Value);
                                elseif isa(directive.Value, 'double')
                                    v = directive.Value;
                                else
                                    throw(MException(Obj.ExceptionId, "Bad BaudRate must be either a 'string' or a 'double' (not a '%s')", ...
                                        class(directive.Value)))
                                end
                                Obj.Device.BaudRate = v;
                            end
                            Obj.Store('directive-response') = Obj.Device.BaudRate;
                        catch ME
                            Obj.Store('directive-response') = ME;
                        end
                        remove(Obj.Store, 'directive');
                        continue

                    elseif strcmp(directive.Name, 'locked')
                        if ~isempty(directive.Value) && islogical(directive.Value)
                            Obj.Locked = directive.Value;
                        end
                        Obj.Store('directive-response') = Obj.Locked;
                        remove(Obj.Store, 'directive')
                        continue

                    elseif strcmp(directive.Name, 'monitoring')
                        if ~isempty(directive.Value) && islogical(directive.Value)
                            Obj.Monitoring = directive.Value;
                        end
                        Obj.Store('directive-response') = Obj.Monitoring;
                        remove(Obj.Store, 'directive')
                        continue

                    else
                        Obj.Store('directive-response') = MException(Obj.ExceptionId, sprintf("Invalid directive '%s'", directive));
                        remove(Obj.Store, 'directive');
                        continue
        
                    end
                end
        
                if Obj.Connected
                    %
                    % When connected:
                    % - if there's a pending command, send it to the device
                    % - otherwise, if the status interval has expired, send a status request to the device
                    %
                    if isKey(Obj.Store, 'command')
                        %
                        % Commands are structures with the fields:
                        %  - Commands: array of strings. Will be sent to the device with an (optional) delay in-between
                        %  - NoReplies: array of logicals. Whether to expect a repply for the respective command
                        %

                        if ~Obj.Locked
                            while Obj.DeviceIsBusy
                                Obj.log(Func + "for command: deviceIsBusy");
                                pause(.1);
                            end
                        end

                        Obj.Store('command-response') = Obj.deviceTransaction(Obj.Store("command"));
                        Obj.LastInteraction = clock;
                        remove(Obj.Store, 'command');

                    else

                        if Obj.Monitoring && (isempty(Obj.LastInteraction) || round(etime(clock,Obj.LastInteraction) * 1000) > milliseconds(Obj.Interval))
                            if Obj.Locked
                                continue
                            end

                            while Obj.DeviceIsBusy
                                pause(.1);
                            end

                            Obj.Store('status') = Obj.deviceTransaction(Obj.StatusCommand);
                            Obj.LastInteraction = clock;
                        end
                    end
                end

                pause(seconds(Obj.EndOfLoopDelay)); % let the CPU breathe
            end
        end
        
        function Obj = disconnect(Obj)
            if isvalid(Obj.Device)
                delete(Obj.Device);
            end
            Obj.Connected = false;
            remove(Obj.Store, 'directive-response');
            remove(Obj.Store, 'response');
            remove(Obj.Store, 'connected');
        end

        %
        % Sends one or more commands to the device, as one transaction
        % 
        function Ret = deviceTransaction(Obj, Commands)
            arguments
                Obj
                Commands
            end

            Func = "deviceTransaction: ";
            Ncommands = numel(Commands);
            Ret(1, Ncommands) = inst.SerialResponse;

            if ~Obj.Locked
                Obj.DeviceIsBusy = true;    % guard ON
            end

            for Idx = 1:Ncommands
                Obj.Device.flush

                Command = Commands(Idx).Command;
                NeedsReply = Commands(Idx).NeedsReply;

                Start = datetime('now');
                try
                    if (Obj.HasTerminator)
                        Obj.Device.writeline(Command);
                    else
                        Obj.Device.write(Command, length(Command));
                    end
                catch ME
                    Ret(Idx) = inst.SerialResponse(ME, datetime('now'));
                    continue
                end
    
                if NeedsReply
                    try
                        if Obj.HasTerminator
                            Line = Obj.Device.readline;
                        else
                            if ~isempty(Obj.ResponseTime)
                                pause(seconds(Obj.ResponseTime));
                            end
                            Line = Obj.Device.read(1024, uint8);
                        end
                    catch ME
                        Ret(Idx) = inst.SerialResponse(ME, datetime('now'));
                        Obj.log(Func + "command(%d): '%s' (exception: '%s')", Idx, Command, ME.message);
                        continue
                    end

                    if isempty(Line)
                        msg = sprintf("No response for command '%s' within %d seconds", Command, Obj.Device.Timeout);
                        Obj.log(Func + "command(%d): %15s (exception: '%s')", Idx, sprintf("'%s'", Command), msg);
                        Ret(Idx) = inst.SerialResponse(MException(Obj.ExceptionId, msg), datetime('now'));
                        continue
                    end
                    if endsWith(Line, Obj.Eol)
                        Line = replace(Line, Obj.Eol, '');
                    end
                        
                    if isa(Obj.Validator, 'function_handle') && ~isempty(Obj.Validator)
                        Obj.Validator(Line); % may throw exception
                    end   

                    Ret(Idx) = inst.SerialResponse(Line, datetime('now'));
                    Obj.log(Func + "command(%d): %15s, reply: '%s' (%s)", Idx, sprintf("'%s'", Command), Ret(Idx).Value, between(Start, datetime('now'), 'time'));
                else
                    Ret(Idx) = inst.SerialResponse([], datetime('now'));
                    Obj.log(Func + "command(%d): %15s (no-reply) (%s)", Idx, sprintf("'%s'", Command), between(Start, datetime('now'), 'time'));
                end

                if ~isempty(Obj.InterCommand) && Idx ~= Ncommands
                    pause(seconds(Obj.InterCommand));
                end
            end

            if ~Obj.Locked
                Obj.DeviceIsBusy = false;   % guard OFF
            end
        end

        function log(Obj, varargin)
            persistent logger;
        
            if isempty(logger)
                logger = MsgLogger(...
                    FileName=sprintf('/var/log/ocs/SerialDevice-%s.txt', replace(Obj.PortPath, '/', '_')), ...
                    LoadConfig=false, ...
                    Console=false);
            end
        
            varargin{1} = "[lower] " + varargin{1};
            logger.msgLog(LogLevel.Debug, varargin{:});
        end

    end


end