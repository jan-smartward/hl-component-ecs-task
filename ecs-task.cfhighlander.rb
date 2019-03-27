CfhighlanderTemplate do
  Description "ecs-task - #{component_name} - #{component_version}"

  Parameters do
    ComponentParam 'EnvironmentName', 'dev', isGlobal: true
  end

end
