package io.github.cjsan30.reserveroom;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.cjsan30.reserveroom.member.Member;
import io.github.cjsan30.reserveroom.member.Role;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.transaction.annotation.Transactional;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
@Transactional
class SeedAdminMigrationTests {

	private static final String ADMIN_EMAIL = "admin@reserve-room.local";

	@Autowired
	EntityManager entityManager;

	@Test
	void seedAdminExistsWithBcryptHash() {
		Member admin = entityManager
			.createQuery("select m from Member m where m.email = :email", Member.class)
			.setParameter("email", ADMIN_EMAIL)
			.getSingleResult();

		assertThat(admin.getRole()).isEqualTo(Role.ADMIN);
		assertThat(admin.getCreatedAt()).isNotNull();
		assertThat(admin.getPasswordHash())
			.isNotEqualTo("admin-dev-password")
			.matches("^\\$2[aby]\\$10\\$[./A-Za-z0-9]{53}$");
		assertThat(new BCryptPasswordEncoder().matches("admin-dev-password", admin.getPasswordHash())).isTrue();
	}

}
