/* Illustrative project panels; never change connection or device status. */
const workspaceOriginalImports=importsPage,workspaceOriginalOffline=offlinePage,workspaceOriginalSettings=platformSettingsPage,workspaceOriginalConnections=connectionsPage;
importsPage=function(){return workspaceOriginalImports()+WorkspaceSamples.preview(state,activeProject().id,'imports',escapeHTML);};
offlinePage=function(){return workspaceOriginalOffline()+WorkspaceSamples.preview(state,activeProject().id,'offline',escapeHTML);};
platformSettingsPage=function(){return workspaceOriginalSettings()+WorkspaceSamples.preview(state,activeProject().id,'settings',escapeHTML);};
connectionsPage=function(){return WorkspaceSamples.preview(state,activeProject().id,'connections',escapeHTML)+workspaceOriginalConnections();};
