CloudFormation do

  log_retention = 7 unless defined?(log_retention)
  Resource('LogGroup') {
    Type 'AWS::Logs::LogGroup'
    Property('LogGroupName', Ref('AWS::StackName'))
    Property('RetentionInDays', "#{log_retention}")
  }

  definitions, task_volumes = Array.new(2){[]}

  task_definition.each do |task_name, task|

    env_vars, mount_points, ports = Array.new(3){[]}

    name = task.has_key?('name') ? task['name'] : task_name

    image_repo = task.has_key?('repo') ? "#{task['repo']}/" : ''
    image_name = task.has_key?('image') ? task['image'] : task_name
    image_tag = task.has_key?('tag') ? "#{task['tag']}" : 'latest'
    image_tag = task.has_key?('tag_param') ? Ref("#{task['tag_param']}") : image_tag

    # create main definition
    task_def =  {
      Name: name,
      Image: FnJoin('',[ image_repo, image_name, ":", image_tag ]),
      LogConfiguration: {
        LogDriver: 'awslogs',
        Options: {
          'awslogs-group' => Ref("LogGroup"),
          "awslogs-region" => Ref("AWS::Region"),
          "awslogs-stream-prefix" => name
        }
      }
    }

    task_def.merge!({ MemoryReservation: task['memory'] }) if task.has_key?('memory')
    task_def.merge!({ Memory: task['memory_hard'] }) if task.has_key?('memory_hard')
    task_def.merge!({ Cpu: task['cpu'] }) if task.has_key?('cpu')

    task_def.merge!({ Ulimits: task['ulimits'] }) if task.has_key?('ulimits')


    if !(task['env_vars'].nil?)
      task['env_vars'].each do |name,value|
        split_value = value.to_s.split(/\${|}/)
        if split_value.include? 'environment'
          fn_join = split_value.map { |x| x == 'environment' ? [ Ref('EnvironmentName'), '.', FnFindInMap('AccountId',Ref('AWS::AccountId'),'DnsDomain') ] : x }
          env_value = FnJoin('', fn_join.flatten)
        elsif value == 'cf_version'
          env_value = cf_version
        else
          env_value = value
        end
        env_vars << { Name: name, Value: env_value}
      end
    end

    task_def.merge!({Environment: env_vars }) if env_vars.any?

    # add links
    if task.key?('links')
      task['links'].each do |links|
      task_def.merge!({ Links: [ links ] })
      end
    end

    # add entrypoint
    if task.key?('entrypoint')
      task['entrypoint'].each do |entrypoint|
      task_def.merge!({ EntryPoint: entrypoint })
      end
    end

    # By default Essential is true, switch to false if `not_essential: true`
    task_def.merge!({ Essential: false }) if task['not_essential']

    # add docker volumes
    if task.key?('mounts')
      task['mounts'].each do |mount|
        if mount.is_a? String 
          parts = mount.split(':',2)
          mount_points << { ContainerPath: FnSub(parts[0]), SourceVolume: FnSub(parts[1]), ReadOnly: (parts[2] == 'ro' ? true : false) }
        else
          mount_points << mount
        end
      end
      task_def.merge!({MountPoints: mount_points })
    end

    # volumes from
    if task.key?('volumes_from')
      task['volumes_from'].each do |source_container|
      task_def.merge!({ VolumesFrom: [ SourceContainer: source_container ] })
      end
    end

    # add port
    if task.key?('ports')
      port_mapppings = []
      task['ports'].each do |port|
        port_array = port.to_s.split(":").map(&:to_i)
        mapping = {}
        mapping.merge!(ContainerPort: port_array[0])
        mapping.merge!(HostPort: port_array[1]) if port_array.length == 2
        port_mapppings << mapping
      end
      task_def.merge!({PortMappings: port_mapppings})
    end

    task_def.merge!({EntryPoint: task['entrypoint'] }) if task.key?('entrypoint')
    task_def.merge!({Command: task['command'] }) if task.key?('command')
    task_def.merge!({HealthCheck: task['healthcheck'] }) if task.key?('healthcheck')
    task_def.merge!({WorkingDirectory: task['working_dir'] }) if task.key?('working_dir')
    task_def.merge!({Privileged: task['privileged'] }) if task.key?('privileged')

    definitions << task_def

  end if defined? task_definition

  # add docker volumes
  if defined?(volumes)
    volumes.each do |volume|
      if volume.is_a? String 
        parts = volume.split(':')
        object = { Name: FnSub(parts[0])}
        object.merge!({ Host: { SourcePath: FnSub(parts[1]) }}) if parts[1]
      else
        object = volume
      end
      task_volumes << object
    end
  end

  if defined?(iam_policies)

    policies = []
    iam_policies.each do |name,policy|
      policies << iam_policy_allow(name,policy['action'],policy['resource'] || '*')
    end

    IAM_Role('TaskRole') do
      AssumeRolePolicyDocument ({
        Statement: [
          {
            Effect: 'Allow',
            Principal: { Service: [ 'ecs-tasks.amazonaws.com' ] },
            Action: [ 'sts:AssumeRole' ]
          },
          {
            Effect: 'Allow',
            Principal: { Service: [ 'ssm.amazonaws.com' ] },
            Action: [ 'sts:AssumeRole' ]
          }
        ]
      })
      Path '/'
      Policies(policies)
    end

    IAM_Role('ExecutionRole') do
      AssumeRolePolicyDocument service_role_assume_policy('ecs-tasks')
      Path '/'
      ManagedPolicyArns ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    end
  end

  Resource('Task') do
    Type 'AWS::ECS::TaskDefinition'
    Property('ContainerDefinitions', definitions)

    if defined?(cpu)
      Property('Cpu', cpu)
    end

    if defined?(memory)
      Property('Memory', memory)
    end

    if defined?(network_mode)
      Property('NetworkMode', network_mode)
    end

    if task_volumes.any?
      Property('Volumes', task_volumes)
    end

    if defined?(iam_policies)
      Property('TaskRoleArn', Ref('TaskRole'))
      Property('ExecutionRoleArn', Ref('ExecutionRole'))
    end

    if defined?(family)
      Property('Family', family)
    end

  end if defined? task_definition

  IAM_Role('Role') do
    AssumeRolePolicyDocument service_role_assume_policy('ecs')
    Path '/'
    ManagedPolicyArns ["arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"]
  end

end
