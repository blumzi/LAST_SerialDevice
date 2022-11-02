%
% A unit test for the SerialDevice class, fashioned after the Copley
% controllers of the Xerxex mount.
%
% Theory of operation:
%  - The constructor creates the SerialDevice with the relevant
%     arguments.  Among others it supplies a validator function handle
%     which only accepts responses starting in "v " (similar to the Copley)
%  - The startTest() method connects to the SerialDevice and then and
%     probes the device (sends a StatusCommand and expects a valid
%     response)
%    If it doesn't get a valid response it tries up to 3 times to:
%     - reset the BaudRate and set it to the OperationalBaudRate (Copley
%       protocol)
%     - get a valid response to the StatusCommand
%    If the probing succeeded, it starts the SerialDevice's in Monitoring
%    functionality to true (instructs the SerialDevice to periodically get
%    the device's status)
%  - The endTest() method tears down the SerialDevice
%
% Logs to: /var/log/ocs/SerialDevice-_dev_ttyUSB0.txt
%

classdef SerialDeviceTest < handle
    properties
        Device inst.SerialDevice
    end

    properties(Hidden=true)
        Logger
        Port = "/dev/ttyS4";
        
        StatCommand = [ ...
            inst.SerialCommand( "0 g r0xa0x", true), ...
            inst.SerialCommand("32 g r0xa0x", true)  ...
        ];

        OperationalBaudRate double = 115200;
    end

    methods
        function Obj = SerialDeviceTest(~)
        
            Obj.Device = inst.SerialDevice(         ...
                Obj.Port,                           ...
                PortSpeed=Obj.OperationalBaudRate,  ...
                Terminator='CR',                    ...
                InterStatus=seconds(10),               ...
                StatusCommand=Obj.StatCommand,      ...
                Validator=@Obj.validator,           ...
                InterCommand=milliseconds(10)       ...
            );    

        end

        function startTest(Obj)
            Func = string([dbstack().name ': ']);

            Obj.log(Func + '================= Test started =====================')

            Obj.Device.connect()
            msg = sprintf("The device connected to '%s' at BaudRate %d is ", Obj.Port, Obj.OperationalBaudRate);
            if Obj.probe
                Obj.log(msg + "operational")
                Obj.Device.Monitoring = true;
            else
                Obj.log(msg + "NOT operational")
            end
        end

        function endTest(Obj)
            Func = string([dbstack().name ': ']);

            Obj.Device.log(Func + '================= Test ended =====================')
            Obj.Device.Monitoring = false;
            Obj.Device.disconnect()
            delete(Obj.Device)
        end
        
        %
        % Checks that the response from the device has the expected format
        % Throws an error if input is erroneous
        %
        function validator(~, input) 
            ErrorPrefix = 'e ';

            if startsWith(input, ErrorPrefix)
                throw(MException("SerialDeviceTester:validator", "input ('%s') starts with '%s'", ErrorPrefix))
            end
        end

        %
        % If the device is not at the OperationalBaudRate, go through the
        % motions to bring it there.
        % Send a status command and check for the expected reply.
        %
        function tf = probe(Obj)

            for tries = 1:3
                Obj.resetAndInitializeBaudRate
                try                   
                    Response = Obj.Device.command(Obj.StatCommand);     % try to get a status value
                catch
                    tf = false;
                    return
                end
    
                if startsWith(Response(1).Value, 'v ') && ...
                        startsWith(Response(2).Value, 'v ')
                    tf = true;
                    return
                end
                pause(2)
            end
        end
        
        %
        % The Copley procedure for resetting and setting the serial line's BaudRate.
        %
        function resetAndInitializeBaudRate(Obj)
            Obj.log("Resetting '%s' to BaudRate %d ...", Obj.Port, Obj.OperationalBaudRate)
            Obj.Device.Locked = true;
            Obj.Device.BaudRate = 1200;
            Obj.Device.command(inst.SerialCommand(" ", false))
            pause(0.1)
            Obj.Device.BaudRate = 9600;
            pause(0.1)
            Obj.Device.command(inst.SerialCommand(sprintf("s r0x90 %d", Obj.OperationalBaudRate), false));
            pause(0.1)
            Obj.Device.BaudRate = Obj.OperationalBaudRate;
            Obj.Device.Locked = false;
            Obj.log("The device connected to '%s' has been initialized to BaudRate %d ", Obj.Port, Obj.OperationalBaudRate)
        end

        function log(Obj, varargin)        
            if isempty(Obj.Logger)
                Obj.Logger = MsgLogger(...
                    FileName=sprintf('/var/log/ocs/SerialDevice-%s.txt', replace(Obj.Port, '/', '_')), ...
                    LoadConfig=false, ...
                    Console=false);
            end
        
            varargin{1} = "[unitTest] " + varargin{1};
            Obj.Logger.msgLog(LogLevel.Debug, varargin{:});
        end
    end
end