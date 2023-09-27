import jenkins.model.*

def JENKINS_URL = System.getenv().get('JENKINS_UI_URL')
def JENKINS_HOME = System.getenv().get('JENKINS_HOME')
file = new File("${JENKINS_HOME}/url-changed")
if (file.exists()) {
    println("[DEBUG] Initialization of Jenkins has been already done")
    return
}
// Set Jenkins URL
urlConfig = JenkinsLocationConfiguration.get()
urlConfig.setUrl(JENKINS_URL)
urlConfig.save()
println("[DEBUG] Jenkins URL Set to ${JENKINS_URL}")

// Create "done" file to avoid multiple runs
String filename = "${JENKINS_HOME}/url-changed"
new File(filename).createNewFile()