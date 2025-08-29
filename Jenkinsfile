pipeline {
  agent any
  environment {
    DOCKERHUB_REPO = "mishraankit062/trend"  // <-- REPLACE
    K8S_NAMESPACE = "trend"
    AWS_REGION = "ap-south-1"
  }
  options { timestamps(); disableConcurrentBuilds() }
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Docker Build') {
      steps {
        script { env.IMAGE_TAG = "build-${env.BUILD_NUMBER}" }
        sh '''
          docker build -t ${DOCKERHUB_REPO}:${IMAGE_TAG} .
          docker tag ${DOCKERHUB_REPO}:${IMAGE_TAG} ${DOCKERHUB_REPO}:latest
        '''
      }
    }
    stage('Push to DockerHub') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'USER', passwordVariable: 'PASS')]) {
          sh '''
            echo "$PASS" | docker login -u "$USER" --password-stdin
            docker push ${DOCKERHUB_REPO}:${IMAGE_TAG}
            docker push ${DOCKERHUB_REPO}:latest
          '''
        }
      }
    }
    stage('Deploy to EKS') {
      steps {
        sh '''
          kubectl get ns ${K8S_NAMESPACE} || kubectl create ns ${K8S_NAMESPACE}
          sed "s|your_dockerhub_username/trend:latest|${DOCKERHUB_REPO}:${IMAGE_TAG}|g" k8s/deployment.yaml | kubectl apply -f -
          kubectl apply -f k8s/service.yaml
          kubectl rollout status deploy/trend-web -n ${K8S_NAMESPACE} --timeout=120s
        '''
      }
    }
    stage('Get Service') { steps { sh 'kubectl get svc trend-lb -n ${K8S_NAMESPACE}' } }
  }
  post {
    success { echo "Deployed successfully." }
    failure { echo "Build or deploy failed." }
  }
}