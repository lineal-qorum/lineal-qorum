import { InstitutionService } from "./institution-service";

export default class LinealQorum {
  private institution: InstitutionService;
  constructor() {
    this.institution = new InstitutionService();
  }

  async deployContract(body: any) {
    return this.institution.deployContract(body);
  }

  async sendOperation(body: any) {
    return this.institution.sendOperation(body);
  }

  async sendTransaction(body: any) {
    return this.institution.createTransaction(body);
  }

  async deployInstitution(body: any) {
    return this.institution.createInstitution(body);
  }

  async getInstitution(contractAddress: any) {
    return this.institution.getInstitutions(contractAddress);
  }
}

